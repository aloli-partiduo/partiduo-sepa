# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Mandats de prélèvement (D-SEPA-007) : séquence du prochain prélèvement,
  # expiration, contrôles de saisie, inscription d'un prélèvement émis.
  # Interne.
  module Mandates
    alias Api = Sepa::Api
    alias FieldError = Partiduo::Api::FieldError

    # Séquence du prochain prélèvement : OOFF pour un mandat ponctuel, FRST
    # tant qu'aucun prélèvement n'a été émis, RCUR ensuite ; `nil` pour un
    # mandat inutilisable (révoqué, ponctuel déjà prélevé).
    def self.next_sequence(row : Mandate) : String?
      return unless row.status == "active"
      return "OOFF" if row.kind == "one_off"
      row.collection_count!.zero? ? "FRST" : "RCUR"
    end

    # Fin de validité d'un mandat récurrent : 36 mois après son dernier
    # usage (ou sa signature s'il n'a jamais servi).
    def self.expires_on(row : Mandate) : Time?
      return unless row.kind == "recurrent" && row.status == "active"
      (row.last_collected_on || row.signed_on!).shift(months: Api::MANDATE_EXPIRY_MONTHS)
    end

    # Mandat actif d'une fiche, le plus récent.
    def self.active_for(code : String) : Mandate?
      Mandate.filter(card_code: code, status: "active").order("-signed_on", "-id").first
    end

    # RUM proposée : `<quick code>-<AAAAMMJJ>-<rang>`, au jeu SEPA.
    def self.generate_rum(code : String, signed_on : Time) : String
      base = Charset.transliterate(code.upcase).gsub(/[^A-Z0-9\-]/, "")[0, 20].presence || "MANDAT"
      rank = Mandate.filter(card_code: code).count + 1
      loop do
        candidate = "#{base}-#{signed_on.to_s("%Y%m%d")}-#{rank}"
        return candidate unless Mandate.filter(rum__iexact: candidate).exists?
        rank += 1
      end
    end

    def self.errors(actor : Partiduo::Api::Actor, input : Api::MandateInput, current : Mandate?) : Array(FieldError)
      errors = [] of FieldError
      card = card_errors(actor, input, errors)
      rum_errors(input.rum.strip, current, errors)
      errors << Records.error("iban", "iban.invalid") unless Codes.valid_iban?(input.iban)
      bic = Codes.compact(input.bic)
      errors << Records.error("bic", "bic.invalid") unless bic.empty? || Codes.valid_bic?(bic)
      errors << Records.error("signed_on", "mandate.signed_on.future") if input.signed_on > Partiduo::Config.today
      kind_errors(input.kind, current, errors)
      name = input.debtor_name.strip.presence || card.try(&.name) || ""
      errors << Records.error("debtor_name", "mandate.debtor_name.blank") if card && Charset.transliterate(name).empty?
      errors
    end

    private def self.card_errors(actor : Partiduo::Api::Actor, input : Api::MandateInput,
                                 errors : Array(FieldError)) : Partiduo::Api::Cards::CardView?
      card = Records.card(actor, input.card_code)
      if input.card_code.strip.empty?
        errors << Records.error("card_code", "mandate.card.blank")
      elsif card.nil?
        errors << Records.error("card_code", "mandate.card.unknown", {"code" => input.card_code.strip})
      end
      card
    end

    # RUM : jeu SEPA, unique, figée après un premier prélèvement.
    private def self.rum_errors(rum : String, current : Mandate?, errors : Array(FieldError)) : Nil
      return if rum.empty?
      if !Charset.valid_identifier?(rum)
        errors << Records.error("rum", "mandate.rum.invalid")
      elsif Mandate.filter(rum__iexact: rum).exclude(id: current.try(&.id)).exists?
        errors << Records.error("rum", "mandate.rum.taken")
      elsif current && current.collection_count!.positive? && rum.upcase != current.rum.to_s.upcase
        errors << Records.error("rum", "mandate.rum.frozen")
      end
    end

    private def self.kind_errors(kind : String, current : Mandate?, errors : Array(FieldError)) : Nil
      if !Api::MANDATE_KINDS.includes?(kind)
        errors << Records.error("kind", "choice.invalid", {"value" => kind})
      elsif current && current.kind != kind && current.collection_count!.positive?
        errors << Records.error("kind", "mandate.kind.frozen")
      end
    end

    def self.apply(actor : Partiduo::Api::Actor, row : Mandate, input : Api::MandateInput) : Mandate
      card = Records.card(actor, input.card_code)
      code = card.try(&.code) || input.card_code.strip
      iban = Codes.compact(input.iban)
      # IBAN changé après un premier prélèvement : la banque en est avertie
      # au suivant (amendement du mandat), avec l'IBAN d'origine.
      if row.collection_count.try(&.positive?) && row.original_iban.to_s.empty? && !row.iban.to_s.empty? && row.iban != iban
        row.original_iban = row.iban
      end
      row.original_iban = "" if row.original_iban == iban
      row.card_code = code
      row.rum = input.rum.strip.presence || row.rum.presence || generate_rum(code, input.signed_on)
      row.signed_on = input.signed_on
      row.iban = iban
      row.bic = Codes.compact(input.bic)
      row.debtor_name = Charset.transliterate(input.debtor_name.strip.presence || card.try(&.name) || code, 70)
      row.kind = input.kind
      row
    end

    # Prélèvement émis (confirmation de l'émission d'un lot) : compteur,
    # date, amendement signalé effacé, mandat ponctuel épuisé.
    def self.record_collection!(row : Mandate, on : Time) : Nil
      row.collection_count = row.collection_count!.to_i32 + 1
      row.last_collected_on = on
      row.original_iban = ""
      row.status = "used" if row.kind == "one_off"
      row.save!
    end
  end
end
