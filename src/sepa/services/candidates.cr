# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Écritures ouvertes qu'un lot peut régler (D-SEPA-009, D-SEPA-015), relues
  # en une requête par le contrat de la Comptabilité
  # (`Partiduo::Api::Accounting.open_items`) : lignes non lettrées des fiches
  # fournisseurs au crédit (ce que l'on doit), ou des fiches clients sous
  # mandat actif au débit (ce que l'on doit nous payer). Un lettrage partiel
  # n'est pas proposé (`include_partial` à faux : son reliquat se saisit à
  # la main). Une ligne déjà engagée dans un paiement vivant n'est plus
  # proposée. Interne.
  module Candidates
    alias Api = Sepa::Api
    alias Acc = Partiduo::Api::Accounting

    # Date d'arrêt des écritures ouvertes : aucune. `open_items` rend les
    # lignes ouvertes *à une date* (une ligne lettrée par une écriture
    # postérieure l'était encore ce jour-là) ; un lot règle ce qui est
    # ouvert *maintenant*, factures datées de demain et paiements déjà
    # saisis pour la semaine prochaine compris : on arrête donc au plus loin.
    OPEN_AS_OF = Time.utc(9999, 12, 31)

    def self.list(actor : Partiduo::Api::Actor, kind : String) : Array(Api::CandidateView)
      taken = Item.filter(entry_line_id__isnull: false).exclude(settlement: "elsewhere").pluck(:entry_line_id)
        .map { |row| row.first.as(Int64) }.to_set
      cards = cards(actor, kind).to_h { |card| {card.code, card} }
      mandates = {} of String => Mandate?
      list = [] of Api::CandidateView
      open_lines(actor, kind).each do |line|
        next if taken.includes?(line.line_id)
        card = cards[line.card_code]? || next
        mandate = kind == "debit" ? mandates.put_if_absent(card.code) { Mandates.active_for(card.code) } : nil
        next if kind == "debit" && mandate.nil?
        list << candidate(card, line, kind, mandate)
      end
      list.sort_by! { |item| {(item.due_date || item.date).to_unix, item.card_code, item.line_id} }
    end

    # Lignes ouvertes des fiches de la nature que règle le lot, du côté qu'il
    # règle, en une requête ; exige `accounting.entry.read`.
    def self.open_lines(actor : Partiduo::Api::Actor, kind : String) : Array(Acc::PartyOpenItemView)
      debit = kind == "debit"
      Acc.open_items(actor, debit ? "customer" : "supplier", OPEN_AS_OF, include_partial: false).select do |line|
        line.matching_id.nil? && (debit ? line.side.debit? : line.side.credit?)
      end
    end

    # Index des lignes ouvertes par identifiant de ligne, pour contrôler
    # tout un lot avec une seule lecture.
    def self.open_index(actor : Partiduo::Api::Actor, kind : String) : Hash(Int64, Acc::PartyOpenItemView)
      open_lines(actor, kind).to_h { |line| {line.line_id, line} }
    end

    # Montant ouvert d'une ligne de la fiche `code`, ou `nil` si elle ne
    # l'est plus.
    def self.open_amount(actor : Partiduo::Api::Actor, code : String, kind : String, line_id : Int64) : BigDecimal?
      open_index(actor, kind)[line_id]?.try { |line| line.card_code == code ? line.amount : nil }
    end

    # Fiches de la nature, lues avec les droits de l'acteur
    # (`cards.card.read`) : leur IBAN est celui des virements.
    private def self.cards(actor : Partiduo::Api::Actor, kind : String) : Array(Partiduo::Api::Cards::CardView)
      nature = kind == "debit" ? "customer" : "supplier"
      Partiduo::Api::Cards.cards(actor, Partiduo::Api::Cards::CardQuery.new(kind: nature, enabled: nil, limit: 10_000))
    end

    private def self.candidate(card : Partiduo::Api::Cards::CardView, line : Acc::PartyOpenItemView, kind : String,
                               mandate : Mandate?) : Api::CandidateView
      iban = mandate ? mandate.iban.to_s : Codes.compact(card.iban)
      problem = if iban.empty?
                  "iban.blank"
                elsif !Codes.valid_iban?(iban)
                  "iban.invalid"
                end
      Api::CandidateView.new(
        line_id: line.line_id, entry_id: line.entry_id, card_code: card.code, card_name: card.name, date: line.date,
        due_date: line.due_date, ledger_code: line.ledger_code, receipt: line.receipt, label: line.label,
        amount: line.amount, iban: iban, mandate_id: mandate.try(&.id.try(&.to_i64)), problem: problem,
      )
    end
  end
end
