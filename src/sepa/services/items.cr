# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Composition d'un lot (D-SEPA-003, D-SEPA-009) : paiements tirés des
  # écritures ouvertes ou saisis, contrôles de saisie, référence de bout en
  # bout. Interne.
  module Items
    alias Api = Sepa::Api
    alias FieldError = Partiduo::Api::FieldError

    # Saisie d'un lot : genre, journal visible, date d'exécution ouvrée,
    # pas dans le passé (un prélèvement : au plus tôt le jour ouvré suivant,
    # D-SEPA-008), libellé au jeu SEPA.
    def self.batch_errors(actor : Partiduo::Api::Actor, input : Api::BatchInput) : Array(FieldError)
      errors = [] of FieldError
      errors << Records.error("kind", "choice.invalid", {"value" => input.kind}) unless Api::KINDS.includes?(input.kind)
      if input.kind == "debit" && Settings.household?
        errors << Records.error("kind", "batch.debit_household")
      end
      Records.financial_ledger(actor, input.ledger_id, "ledger_id", errors)
      date_errors(input.kind, input.requested_on, errors)
      errors << Records.error("label", "batch.label.too_long", {"max" => "140"}) if input.label.strip.size > 140
      errors
    end

    def self.date_errors(kind : String, date : Time, errors : Array(FieldError), field : String = "requested_on") : Nil
      today = Partiduo::Config.today
      earliest = kind == "debit" ? today + 1.day : today
      if date < earliest
        errors << Records.error(field, kind == "debit" ? "date.too_soon" : "date.past")
      elsif !Calendar.business_day?(date)
        errors << Records.error(field, "date.not_business_day",
          {"next" => Calendar.next_business_day(date).to_s("%Y-%m-%d")})
      elsif date > today + 365.days
        errors << Records.error(field, "date.too_far")
      end
    end

    def self.apply_batch(row : Batch, input : Api::BatchInput, settings : Api::SettingsView) : Batch
      row.kind = input.kind
      row.ledger_id = input.ledger_id
      row.requested_on = input.requested_on
      row.label = Charset.transliterate(input.label.strip, 140)
      row.batch_booking = input.batch_booking.nil? ? settings.batch_booking : input.batch_booking == true
      row
    end

    # Saisie d'un paiement : fiche connue (de la nature du lot), montant au
    # centime dans les bornes SEPA, IBAN et BIC valides, communication et
    # nom au jeu SEPA ; pour un prélèvement, un mandat actif de la fiche.
    # `limit` : montant ouvert de l'écriture réglée.
    def self.item_errors(actor : Partiduo::Api::Actor, batch : Batch, input : Api::ItemInput,
                         limit : BigDecimal? = nil) : Array(FieldError)
      errors = [] of FieldError
      card = card_errors(actor, input.card_code, errors)
      amount_errors(input.amount, limit, errors)
      if batch.kind == "debit"
        if card && Mandates.active_for(card.code).nil?
          errors << Records.error("card_code", "item.mandate.none", {"code" => card.code})
        end
      else
        bank_errors(input, card, errors)
      end
      remittance = input.remittance.strip
      errors << Records.error("remittance", "item.remittance.too_long", {"max" => "140"}) if remittance.size > 140
      errors
    end

    private def self.card_errors(actor : Partiduo::Api::Actor, code : String,
                                 errors : Array(FieldError)) : Partiduo::Api::Cards::CardView?
      card = Records.card(actor, code)
      if code.strip.empty?
        errors << Records.error("card_code", "item.card.blank")
      elsif card.nil?
        errors << Records.error("card_code", "item.card.unknown", {"code" => code.strip})
      end
      card
    end

    # IBAN (obligatoire) et BIC (facultatif) d'un virement : saisis, sinon
    # ceux de la fiche.
    private def self.bank_errors(input : Api::ItemInput, card : Partiduo::Api::Cards::CardView?,
                                 errors : Array(FieldError)) : Nil
      iban = Codes.compact(input.iban.presence || card.try(&.iban) || "")
      if iban.empty?
        errors << Records.error("iban", "iban.blank")
      elsif !Codes.valid_iban?(iban)
        errors << Records.error("iban", "iban.invalid")
      end
      bic = Codes.compact(input.bic.presence || card.try(&.bic) || "")
      errors << Records.error("bic", "bic.invalid") unless bic.empty? || Codes.valid_bic?(bic)
    end

    def self.amount_errors(amount : BigDecimal, limit : BigDecimal?, errors : Array(FieldError)) : Nil
      if amount <= 0
        errors << Records.error("amount", "item.amount.positive")
      elsif amount > Api::MAX_AMOUNT
        errors << Records.error("amount", "item.amount.too_large")
      elsif amount.round(2) != amount
        errors << Records.error("amount", "item.amount.cents")
      elsif limit && amount > limit
        errors << Records.error("amount", "item.amount.over_open", {"amount" => limit.to_s})
      end
    end

    # Montant ramené à l'échelle du centime (`120.0000` → `120.00`), sans
    # arrondi : un montant de plus de deux décimales est refusé avant.
    def self.cents(value : BigDecimal) : BigDecimal
      BigDecimal.new(XmlBuilder.amount(value))
    end

    # Remplit un paiement d'une saisie ; les coordonnées vides viennent de
    # la fiche (virement) ou du mandat (prélèvement).
    def self.apply_item(actor : Partiduo::Api::Actor, batch : Batch, row : Item, input : Api::ItemInput) : Item
      card = Records.card(actor, input.card_code)
      code = card.try(&.code) || input.card_code.strip
      row.card_code = code
      row.amount = cents(input.amount)
      row.remittance = Charset.transliterate(input.remittance.strip, 140)
      batch.kind == "debit" ? debtor!(row, input, card, code) : creditor!(row, input, card, code)
      row
    end

    # Débiteur d'un prélèvement : coordonnées du mandat actif de la fiche.
    private def self.debtor!(row : Item, input : Api::ItemInput, card : Partiduo::Api::Cards::CardView?, code : String) : Nil
      mandate = Mandates.active_for(code)
      row.mandate_id = mandate.try(&.id)
      row.name = Charset.transliterate(input.name.strip.presence || mandate.try(&.debtor_name) || card.try(&.name) || code, 70)
      row.iban = mandate.try(&.iban.to_s) || ""
      row.bic = mandate.try(&.bic.to_s) || ""
    end

    # Créancier d'un virement : coordonnées saisies, sinon celles de la fiche.
    private def self.creditor!(row : Item, input : Api::ItemInput, card : Partiduo::Api::Cards::CardView?, code : String) : Nil
      row.name = Charset.transliterate(input.name.strip.presence || card.try(&.name) || code, 70)
      row.iban = Codes.compact(input.iban.presence || card.try(&.iban) || "")
      row.bic = Codes.compact(input.bic.presence || card.try(&.bic) || "")
    end

    # Paiement tiré d'une écriture ouverte : montant ouvert entier,
    # communication = numéro de la facture du fournisseur s'il est connu,
    # sinon pièce et libellé.
    def self.from_candidate(actor : Partiduo::Api::Actor, batch : Batch, candidate : Api::CandidateView) : Item
      row = Item.new(batch_id: batch.id, settlement: "none")
      input = Api::ItemInput.new(card_code: candidate.card_code, amount: candidate.amount,
        remittance: remittance(actor, candidate))
      apply_item(actor, batch, row, input)
      row.entry_line_id = candidate.line_id
      row.entry_id = candidate.entry_id
      row.receipt = candidate.receipt.to_s[0, 40]
      row.due_on = candidate.due_date
      row
    end

    def self.remittance(actor : Partiduo::Api::Actor, candidate : Api::CandidateView) : String
      number = begin
        Partiduo::Api::Accounting.received_invoice_for_entry(actor, candidate.entry_id).try(&.number)
      rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
        nil
      end
      text = number ? number : [candidate.receipt, candidate.label].compact.reject(&.empty?).join(" ")
      Charset.transliterate(text, 140)
    end

    # Référence de bout en bout : `PD<lot>-<paiement>`, suivie de la pièce
    # réglée si elle tient dans les 35 caractères.
    def self.end_to_end_id(batch_id : Int64, row : Item) : String
      base = "PD#{batch_id}-#{row.id}"
      receipt = Charset.transliterate(row.receipt.to_s).gsub(/[^A-Za-z0-9\-]/, "")
      candidate = receipt.empty? ? base : "#{base}-#{receipt}"
      candidate.size <= 35 ? candidate : base
    end

    # Rangs et références de bout en bout recalculés.
    def self.renumber!(batch : Batch) : Nil
      Item.filter(batch_id: batch.id).order(:position, :id).to_a.each_with_index(1) do |row, index|
        row.position = index
        row.end_to_end_id = end_to_end_id(batch.id!.to_i64, row)
        row.save!
      end
    end
  end
end
