# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Réglages du dossier : la ligne enregistrée, ou les valeurs par défaut
  # (règlement passé, comptabilisation groupée), complétés de ce que la
  # société porte (identifiant créancier SEPA, validation à une ou deux
  # personnes, D-SEPA-016, D-SEPA-017). Interne.
  module Settings
    alias Api = Sepa::Api

    def self.row : Setting?
      Setting.all.order(:id).first
    end

    def self.view : Api::SettingsView
      stored = row
      company = company_settings
      Api::SettingsView.new(
        settlement_mode: stored.try(&.settlement_mode.to_s) || "post",
        batch_booking: stored.nil? || stored.batch_booking == true,
        ledger_id: stored.try(&.ledger_id.try(&.to_i64)),
        stored: !stored.nil?,
        creditor_identifier: company.try(&.creditor_identifier) || "",
        approval_mode: company.try(&.approval_mode) || "single",
        legacy_creditor_identifier: stored.try(&.legacy_creditor_identifier.to_s) || "",
      )
    end

    def self.apply(row : Setting, input : Api::SettingsInput) : Setting
      row.settlement_mode = input.settlement_mode
      row.batch_booking = input.batch_booking
      row.ledger_id = input.ledger_id
      row.legacy_creditor_identifier = "" if input.discard_legacy_creditor_identifier
      row
    end

    # Identifiant créancier SEPA (ICS) de la société, forme compacte ; vide
    # s'il n'est pas renseigné.
    def self.creditor_identifier : String
      Codes.compact(company_settings.try(&.creditor_identifier) || "")
    end

    # Nom du donneur d'ordre ou du créancier : la raison sociale (ou le nom
    # du foyer) de la configuration société.
    def self.company_name : String
      company_settings.try(&.company_name) || ""
    end

    # Dossier d'un foyer (ADR-011 A3) : pas de prélèvement (D-SEPA-002).
    def self.household? : Bool
      company_settings.try(&.household?) || false
    end

    # Configuration société, lue par le contrat avec l'acteur système ;
    # `nil` avant le provisionnement.
    def self.company_settings : Partiduo::Api::Core::SettingsView?
      Partiduo::Api::Core.settings(Partiduo::Api::Actor.system)
    rescue Partiduo::Api::NotFound
      nil
    end
  end
end
