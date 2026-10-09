# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Contrôle complet d'un lot avant de le figer puis d'en produire le
  # fichier (D-SEPA-005, D-SEPA-006) : compte bancaire du journal, date,
  # identifiant créancier, chaque paiement (IBAN, BIC, montant, jeu de
  # caractères, écriture toujours ouverte, mandat valable). Interne.
  module Preparation
    alias Api = Sepa::Api
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError

    # Compte bancaire du donneur d'ordre (virement) ou du créancier
    # (prélèvement) : la fiche Banque du journal financier.
    record Account, name : String, iban : String, bic : String, currency : String

    # Compte du journal du lot ; erreurs sur `ledger_id` sinon. La fiche
    # Banque est relue avec l'acteur système : le journal, lui, a déjà été
    # contrôlé avec les droits de l'acteur.
    def self.account(actor : Partiduo::Api::Actor, batch : Batch, errors : Array(FieldError)) : Account?
      ledger = Records.visible_ledgers(actor).find(&.id.==(batch.ledger_id!.to_i64))
      if ledger.nil?
        errors << Records.error("ledger_id", "ledger.invalid")
        return
      end
      unless ledger.currency_code.empty? || ledger.currency_code == "EUR"
        errors << Records.error("ledger_id", "ledger.currency", {"currency" => ledger.currency_code})
      end
      card = ledger.bank_card_code.try { |code| Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code) }
      iban = Codes.compact(card.try(&.iban) || "")
      bic = Codes.compact(card.try(&.bic) || "")
      if iban.empty?
        errors << Records.error("ledger_id", "ledger.iban_blank", {"code" => ledger.code})
      elsif !Codes.valid_iban?(iban)
        errors << Records.error("ledger_id", "ledger.iban_invalid", {"code" => ledger.code})
      end
      errors << Records.error("ledger_id", "ledger.bic_invalid", {"code" => ledger.code}) unless bic.empty? || Codes.valid_bic?(bic)
      name = Charset.transliterate(Settings.company_name, 70)
      errors << Records.error(FieldError::BASE, "company.name_blank") if name.empty?
      Account.new(name, iban, bic, "EUR")
    end

    # Erreurs du lot entier ; champ `items[<rang>].<champ>` pour un paiement.
    def self.errors(actor : Partiduo::Api::Actor, batch : Batch, items : Array(Item)) : Array(FieldError)
      errors = [] of FieldError
      account(actor, batch, errors)
      Items.date_errors(batch.kind.to_s, batch.requested_on!, errors)
      if items.empty?
        errors << Records.error(FieldError::BASE, "batch.empty")
      elsif items.size > Api::MAX_ITEMS
        errors << Records.error(FieldError::BASE, "batch.too_many", {"max" => Api::MAX_ITEMS.to_s})
      end
      if batch.kind == "debit"
        ics = Settings.view.creditor_identifier
        if ics.empty?
          errors << Records.error(FieldError::BASE, "settings.ics_blank")
        elsif !Codes.valid_ics?(ics)
          errors << Records.error(FieldError::BASE, "settings.ics_invalid")
        end
      end
      open = {} of String => Array(Acc::StatementLineView)
      items.each { |row| item_errors(actor, batch, row, open, errors) }
      errors
    end

    private def self.item_errors(actor : Partiduo::Api::Actor, batch : Batch, row : Item,
                                 open : Hash(String, Array(Acc::StatementLineView)), errors : Array(FieldError)) : Nil
      field = "items[#{row.position}]"
      params = {"position" => row.position.to_s, "name" => row.name.to_s}
      errors << Records.error("#{field}.name", "item.name.blank", params) if row.name.to_s.strip.empty?
      amount_errors = [] of FieldError
      Items.amount_errors(row.amount!, nil, amount_errors)
      errors << Records.error("#{field}.amount", "item.amount_invalid", params) unless amount_errors.empty?
      unless Charset.valid?(row.remittance.to_s) && Charset.valid_identifier?(row.end_to_end_id.to_s)
        errors << Records.error("#{field}.remittance", "item.charset", params)
      end
      if batch.kind == "debit"
        mandate_errors(batch, row, field, params, errors)
      else
        iban_errors(row.iban.to_s, row.bic.to_s, field, params, errors)
      end
      if line_id = row.entry_line_id.try(&.to_i64)
        lines = open.put_if_absent(row.card_code.to_s) { Candidates.open_lines(actor, row.card_code.to_s, batch.kind.to_s) }
        line = lines.find(&.line_id.==(line_id))
        if line.nil?
          errors << Records.error("#{field}.entry_line_id", "item.line_closed", params.merge({"receipt" => row.receipt.to_s}))
        else
          limit = batch.kind == "debit" ? line.debit : line.credit
          if row.amount! > limit
            errors << Records.error("#{field}.amount", "item.amount.over_open", params.merge({"amount" => limit.to_s}))
          end
        end
      end
    end

    private def self.iban_errors(iban : String, bic : String, field : String, params : Hash(String, String),
                                 errors : Array(FieldError)) : Nil
      if iban.empty?
        errors << Records.error("#{field}.iban", "item.iban_blank", params)
      elsif !Codes.valid_iban?(iban)
        errors << Records.error("#{field}.iban", "item.iban_invalid", params)
      end
      errors << Records.error("#{field}.bic", "item.bic_invalid", params) unless bic.empty? || Codes.valid_bic?(bic)
    end

    private def self.mandate_errors(batch : Batch, row : Item, field : String, params : Hash(String, String),
                                    errors : Array(FieldError)) : Nil
      mandate = row.mandate_id.try { |id| Mandate.filter(id: id).first }
      if mandate.nil? || mandate.status != "active"
        errors << Records.error("#{field}.mandate", "item.mandate_inactive", params)
        return
      end
      if mandate.signed_on! > batch.requested_on!
        errors << Records.error("#{field}.mandate", "item.mandate_not_signed", params)
      end
      if (expiry = Mandates.expires_on(mandate)) && batch.requested_on! > expiry
        errors << Records.error("#{field}.mandate", "item.mandate_expired", params.merge({"date" => expiry.to_s("%Y-%m-%d")}))
      end
      iban_errors(mandate.iban.to_s, mandate.bic.to_s, field, params, errors)
    end

    # Fige le lot préparé : coordonnées et séquence des prélèvements reprises
    # du mandat (RUM, signature, IBAN, amendement).
    def self.freeze!(batch : Batch, items : Array(Item)) : Nil
      return unless batch.kind == "debit"
      items.each do |row|
        mandate = row.mandate_id.try { |id| Mandate.filter(id: id).first } || next
        row.sequence_type = Mandates.next_sequence(mandate) || ""
        row.mandate_rum = mandate.rum.to_s
        row.mandate_signed_on = mandate.signed_on
        row.iban = mandate.iban.to_s
        row.bic = mandate.bic.to_s
        row.name = mandate.debtor_name.to_s
        row.original_iban = mandate.original_iban.to_s
        row.save!
      end
    end

    # Lot rouvert : séquences et instantanés des mandats effacés.
    def self.unfreeze!(items : Array(Item)) : Nil
      items.each do |row|
        next if row.sequence_type.to_s.empty? && row.mandate_rum.to_s.empty?
        row.sequence_type = ""
        row.mandate_rum = ""
        row.mandate_signed_on = nil
        row.original_iban = ""
        row.save!
      end
    end
  end
end
