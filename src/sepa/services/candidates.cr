# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Écritures ouvertes qu'un lot peut régler (D-SEPA-009), relues par le
  # contrat de la Comptabilité : relevé non lettré de chaque fiche
  # fournisseur (lignes au crédit : ce que l'on doit) ou de chaque client
  # sous mandat actif (lignes au débit : ce que l'on doit nous payer).
  # Une ligne déjà engagée dans un paiement vivant n'est plus proposée.
  # Interne.
  module Candidates
    alias Api = Sepa::Api
    alias Acc = Partiduo::Api::Accounting

    def self.list(actor : Partiduo::Api::Actor, kind : String) : Array(Api::CandidateView)
      taken = Item.filter(entry_line_id__isnull: false).exclude(settlement: "elsewhere").pluck(:entry_line_id)
        .map { |row| row.first.as(Int64) }.to_set
      list = [] of Api::CandidateView
      cards(actor, kind).each do |card|
        mandate = kind == "debit" ? Mandates.active_for(card.code) : nil
        next if kind == "debit" && mandate.nil?
        open_lines(actor, card.code, kind).each do |line|
          next if taken.includes?(line.line_id)
          list << candidate(card, line, kind, mandate)
        end
      end
      list.sort_by! { |item| {(item.due_date || item.date).to_unix, item.card_code, item.line_id} }
    end

    # Lignes non lettrées de la fiche, du côté que le lot règle ; un
    # lettrage partiel n'est pas proposé (son reliquat se saisit à la main).
    def self.open_lines(actor : Partiduo::Api::Actor, code : String, kind : String) : Array(Acc::StatementLineView)
      open_lines?(actor, code, kind) || [] of Acc::StatementLineView
    end

    # Idem, `nil` si la fiche n'existe plus.
    def self.open_lines?(actor : Partiduo::Api::Actor, code : String, kind : String) : Array(Acc::StatementLineView)?
      statement = Acc.account_statement(actor, Acc::StatementQuery.new(card: code, unmatched_only: true))
      statement.lines.select do |line|
        line.matching_id.nil? && (kind == "debit" ? line.debit > 0 : line.credit > 0)
      end
    rescue Partiduo::Api::NotFound
      nil
    end

    # Montant ouvert d'une ligne de la fiche, ou `nil` si elle ne l'est plus.
    def self.open_amount(actor : Partiduo::Api::Actor, code : String, kind : String, line_id : Int64) : Acc::StatementLineView?
      open_lines(actor, code, kind).find(&.line_id.==(line_id))
    end

    private def self.cards(actor : Partiduo::Api::Actor, kind : String) : Array(Partiduo::Api::Cards::CardView)
      nature = kind == "debit" ? "customer" : "supplier"
      Partiduo::Api::Cards.cards(actor, Partiduo::Api::Cards::CardQuery.new(kind: nature, enabled: nil, limit: 10_000))
    end

    private def self.candidate(card : Partiduo::Api::Cards::CardView, line : Acc::StatementLineView, kind : String,
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
        amount: kind == "debit" ? line.debit : line.credit, iban: iban, mandate_id: mandate.try(&.id.try(&.to_i64)),
        problem: problem,
      )
    end
  end
end
