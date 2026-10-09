# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Lecture des lots, paiements et mandats, et construction des vues du
  # contrat (interne).
  module Records
    alias Api = Sepa::Api
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError

    def self.error(field : String, key : String, params : Hash(String, String) = {} of String => String) : FieldError
      FieldError.new(field, "sepa.errors.#{key}", params)
    end

    # --- Recherche ---------------------------------------------------------------

    # Lot d'un journal visible de l'acteur ; `NotFound` sinon.
    def self.batch!(actor : Partiduo::Api::Actor, id : Int64, lock : Bool = false) : Batch
      query = Batch.filter(id: id)
      query = query.lock if lock
      row = query.first
      raise Partiduo::Api::NotFound.new("sepa_batch", id) if row.nil? || !visible?(actor, row.ledger_id!.to_i64)
      row
    end

    def self.item!(actor : Partiduo::Api::Actor, id : Int64) : Item
      row = Item.filter(id: id).first || raise Partiduo::Api::NotFound.new("sepa_item", id)
      batch!(actor, row.batch_id!.to_i64)
      row
    end

    def self.mandate!(id : Int64, lock : Bool = false) : Mandate
      query = Mandate.filter(id: id)
      query = query.lock if lock
      query.first || raise Partiduo::Api::NotFound.new("sepa_mandate", id)
    end

    # Journaux financiers visibles de l'acteur (droits par journal du
    # socle) : les lots des autres journaux lui sont cachés (D-SEPA-004).
    def self.visible_ledgers(actor : Partiduo::Api::Actor) : Array(Acc::LedgerView)
      Acc.ledgers(actor, Acc::LedgerKind::Financial)
    rescue Partiduo::Api::AccessDenied
      [] of Acc::LedgerView
    end

    def self.visible_ledger_ids(actor : Partiduo::Api::Actor) : Array(Int64)
      visible_ledgers(actor).map(&.id)
    end

    def self.visible?(actor : Partiduo::Api::Actor, ledger_id : Int64) : Bool
      visible_ledger_ids(actor).includes?(ledger_id)
    end

    # Journal financier visible de l'acteur, ou erreur sur `field`.
    def self.financial_ledger(actor : Partiduo::Api::Actor, id : Int64?, field : String,
                              errors : Array(FieldError)) : Acc::LedgerView?
      if id.nil?
        errors << error(field, "ledger.blank")
        return
      end
      ledger = visible_ledgers(actor).find { |item| item.id == id }
      errors << error(field, "ledger.invalid") if ledger.nil?
      ledger
    end

    def self.card(actor : Partiduo::Api::Actor, code : String) : Partiduo::Api::Cards::CardView?
      return if code.strip.empty?
      Partiduo::Api::Cards.card_by_code(actor, code.strip)
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # --- Vues --------------------------------------------------------------------

    def self.batch_views(actor : Partiduo::Api::Actor, rows : Array(Batch), with_items : Bool = false) : Array(Api::BatchView)
      return [] of Api::BatchView if rows.empty?
      ledgers = visible_ledgers(actor).to_h { |ledger| {ledger.id, ledger.code} }
      items = Item.filter(batch_id__in: rows.map(&.id!.to_i64)).order(:position, :id).to_a.group_by(&.batch_id!.to_i64)
      zero = BigDecimal.new(0)
      cards = {} of String => String?
      rows.map do |row|
        id = row.id!.to_i64
        own = items[id]? || [] of Item
        Api::BatchView.new(
          id: id, kind: row.kind.to_s, ledger_id: row.ledger_id!.to_i64, ledger_code: ledgers[row.ledger_id!.to_i64]? || "",
          status: row.status.to_s, label: row.label.to_s, requested_on: row.requested_on!,
          batch_booking: row.batch_booking == true, message_id: row.message_id.to_s,
          attachment_id: row.attachment_id.try(&.to_i64), file_sha256: row.file_sha256.to_s,
          approval_mode: row.approval_mode.to_s, item_count: own.size, total: own.sum(zero, &.amount!),
          to_settle_count: row.status == "issued" ? own.count(&.settlement.==("none")) : 0,
          created_by_id: row.created_by_id.try(&.to_i64), prepared_by_id: row.prepared_by_id.try(&.to_i64),
          prepared_at: row.prepared_at, approved_by_id: row.approved_by_id.try(&.to_i64), approved_at: row.approved_at,
          issued_by_id: row.issued_by_id.try(&.to_i64), issued_at: row.issued_at, issued_on: row.issued_on,
          created_at: row.created_at || Time.utc,
          items: with_items ? item_views(actor, own, row.kind == "debit", cards) : [] of Api::ItemView,
        )
      end
    end

    def self.batch_view(actor : Partiduo::Api::Actor, row : Batch) : Api::BatchView
      batch_views(actor, [row], with_items: true).first
    end

    # Vues des paiements ; `card_iban` relu une fois par fiche (ou par
    # mandat pour un prélèvement), pour signaler un IBAN qui a changé.
    def self.item_views(actor : Partiduo::Api::Actor, rows : Array(Item), debit : Bool,
                        cards = {} of String => String?) : Array(Api::ItemView)
      mandates = Mandate.filter(id__in: rows.compact_map(&.mandate_id)).to_a.to_h { |row| {row.id!.to_i64, row} }
      rows.map do |row|
        code = row.card_code.to_s
        current = if debit
                    row.mandate_id.try { |id| mandates[id.to_i64]?.try(&.iban.to_s) }
                  else
                    cards.put_if_absent(code) { card(actor, code).try { |found| Codes.compact(found.iban) } }
                  end
        Api::ItemView.new(
          id: row.id!.to_i64, batch_id: row.batch_id!.to_i64, position: row.position!.to_i32, card_code: code,
          name: row.name.to_s, iban: row.iban.to_s, bic: row.bic.to_s, amount: row.amount!, remittance: row.remittance.to_s,
          reference_kind: Codes.reference_kind(row.remittance.to_s), end_to_end_id: row.end_to_end_id.to_s,
          entry_line_id: row.entry_line_id.try(&.to_i64), entry_id: row.entry_id.try(&.to_i64), receipt: row.receipt.to_s,
          due_on: row.due_on, mandate_id: row.mandate_id.try(&.to_i64),
          mandate_rum: row.mandate_rum.to_s.presence || row.mandate_id.try { |id| mandates[id.to_i64]?.try(&.rum.to_s) } || "",
          sequence_type: row.sequence_type.to_s, amended: !row.original_iban.to_s.empty?, settlement: row.settlement.to_s,
          settlement_entry_id: row.settlement_entry_id.try(&.to_i64), reversed_entry_id: row.reversed_entry_id.try(&.to_i64),
          card_iban: current, error: stored_error(row),
        )
      end
    end

    def self.item_view(actor : Partiduo::Api::Actor, row : Item) : Api::ItemView
      debit = Batch.filter(id: row.batch_id).first.try(&.kind.==("debit")) || false
      item_views(actor, [row], debit).first
    end

    def self.mandate_views(actor : Partiduo::Api::Actor, rows : Array(Mandate)) : Array(Api::MandateView)
      used = Item.filter(mandate_id__in: rows.map(&.id!.to_i64)).pluck(:mandate_id).map { |row| row.first.as(Int64) }.to_set
      names = {} of String => String?
      rows.map do |row|
        code = row.card_code.to_s
        Api::MandateView.new(
          id: row.id!.to_i64, card_code: code, card_name: names.put_if_absent(code) { card(actor, code).try(&.name) },
          rum: row.rum.to_s, signed_on: row.signed_on!, debtor_name: row.debtor_name.to_s, iban: row.iban.to_s,
          iban_masked: Codes.mask(row.iban.to_s), bic: row.bic.to_s, kind: row.kind.to_s, status: row.status.to_s,
          revoked_on: row.revoked_on, amended: !row.original_iban.to_s.empty?,
          collection_count: row.collection_count!.to_i32, last_collected_on: row.last_collected_on,
          next_sequence: Mandates.next_sequence(row), expires_on: Mandates.expires_on(row),
          in_use: used.includes?(row.id!.to_i64),
        )
      end
    end

    def self.mandate_view(actor : Partiduo::Api::Actor, row : Mandate) : Api::MandateView
      mandate_views(actor, [row]).first
    end

    # Erreur du dernier règlement, gardée sur le paiement.
    def self.stored_error(row : Item) : FieldError?
      key = row.error_key.to_s
      return if key.empty?
      params = begin
        Hash(String, String).from_json(row.error_params.to_s.presence || "{}")
      rescue JSON::ParseException
        {} of String => String
      end
      FieldError.new("base", key, params)
    end

    def self.store_error(row : Item, error : FieldError?) : Nil
      row.error_key = error.try(&.key) || ""
      row.error_params = error.try(&.params.to_json) || ""
    end
  end
end
