# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Règlements d'un lot émis (D-SEPA-010) : une écriture par paiement, dans
  # le journal financier du lot, à la date d'exécution, par
  # `Partiduo::Api::Accounting.post_financial` (le seul service d'écriture,
  # ADR-003 D6), lettrée avec l'écriture ouverte réglée, fichier du lot en
  # pièce jointe, `source` = `sepa:item:<id>`. Jamais en double :
  #
  # * un paiement déjà passé est sauté ;
  # * une écriture non annulée de même `source` (passée par un essai
  #   interrompu) est reprise au lieu d'en passer une autre ;
  # * une écriture ouverte lettrée entre-temps hors du lot (relevé importé,
  #   saisie manuelle) n'est pas réglée une seconde fois : le paiement est
  #   marqué « réglé ailleurs ».
  #
  # Chaque paiement passe dans son point de sauvegarde ; un refus de la
  # Comptabilité (période close…) reste sur le paiement, sans empêcher les
  # autres. Interne.
  module Settlement
    alias Acc = Partiduo::Api::Accounting

    SOURCE = "sepa:item:"

    def self.run(actor : Partiduo::Api::Actor, batch : Batch, rows : Array(Item)) : {Array(Item), Array(Item), Array(Item)}
      posted = [] of Item
      elsewhere = [] of Item
      failed = [] of Item
      open = nil.as(Hash(Int64, Acc::PartyOpenItemView)?)
      known = {} of String => Bool
      rows.each do |row|
        next unless row.settlement == "none"
        if entry_id = existing_entry(actor, row)
          mark_posted(row, entry_id)
          posted << row
          next
        end
        line_id = row.entry_line_id.try(&.to_i64)
        if line_id
          code = row.card_code.to_s
          unless known.put_if_absent(code) { !Records.card(actor, code).nil? }
            Records.store_error(row, Records.error("card_code", "item.card.unknown", {"code" => code}))
            row.save!
            failed << row
            next
          end
          # Écritures ouvertes relues une fois pour tout le lot (D-SEPA-015).
          lines = open ||= Candidates.open_index(actor, batch.kind.to_s)
          unless lines[line_id]?.try(&.card_code.==(code))
            row.settlement = "elsewhere"
            Records.store_error(row, nil)
            row.save!
            elsewhere << row
            next
          end
        end
        if error = post(actor, batch, row, line_id)
          Records.store_error(row, error)
          row.save!
          failed << row
        else
          posted << row
        end
      end
      {posted, elsewhere, failed}
    end

    # Écriture non annulée déjà passée pour ce paiement.
    private def self.existing_entry(actor : Partiduo::Api::Actor, row : Item) : Int64?
      query = Acc::EntryQuery.new(source: "#{SOURCE}#{row.id}", include_cancelled: false, limit: 1)
      Acc.entries(actor, query).first?.try(&.id)
    rescue Partiduo::Api::AccessDenied
      nil
    end

    private def self.mark_posted(row : Item, entry_id : Int64) : Nil
      row.settlement = "posted"
      row.settlement_entry_id = entry_id
      Records.store_error(row, nil)
      row.save!
    end

    # Passe l'écriture d'un paiement ; rend l'erreur, ou `nil`.
    private def self.post(actor : Partiduo::Api::Actor, batch : Batch, row : Item, line_id : Int64?) : Partiduo::Api::FieldError?
      amount = batch.kind == "debit" ? row.amount! : -row.amount!
      label = [row.remittance.to_s.presence, row.name.to_s].compact.first
      line = Acc::PaymentLineInput.new(amount, card: row.card_code.to_s, label: label,
        match_line_ids: line_id ? [line_id] : [] of Int64)
      input = Acc::FinancialInput.new(ledger_id: batch.ledger_id!.to_i64, date: batch.requested_on!, lines: [line],
        attachment_id: batch.attachment_id.try(&.to_i64), source: "#{SOURCE}#{row.id}")
      result = Partiduo::Api::Transaction.run do
        done = Acc.post_financial(actor, input)
        next Partiduo::Api::Result(Int64).failure(done.errors) if done.failure?
        entry = done.value!.first
        mark_posted(row, entry.id)
        Partiduo::Api::Result(Int64).success(entry.id)
      end
      result.success? ? nil : result.errors.first
    end
  end
end
