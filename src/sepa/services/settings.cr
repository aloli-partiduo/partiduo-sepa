# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Réglages du dossier : la ligne enregistrée, ou les valeurs par défaut
  # (validation à une personne, règlement passé, comptabilisation groupée).
  # Interne.
  module Settings
    alias Api = Sepa::Api

    def self.row : Setting?
      Setting.all.order(:id).first
    end

    def self.view : Api::SettingsView
      stored = row
      Api::SettingsView.new(
        approval_mode: stored.try(&.approval_mode.to_s) || "single",
        settlement_mode: stored.try(&.settlement_mode.to_s) || "post",
        batch_booking: stored.nil? || stored.batch_booking == true,
        creditor_identifier: stored.try(&.creditor_identifier.to_s) || "",
        ledger_id: stored.try(&.ledger_id.try(&.to_i64)),
        stored: !stored.nil?,
      )
    end

    def self.apply(row : Setting, input : Api::SettingsInput) : Setting
      row.approval_mode = input.approval_mode
      row.settlement_mode = input.settlement_mode
      row.batch_booking = input.batch_booking
      row.creditor_identifier = Codes.compact(input.creditor_identifier)
      row.ledger_id = input.ledger_id
      row
    end

    # Nom du donneur d'ordre ou du créancier : la raison sociale (ou le nom
    # du foyer) de la configuration société.
    def self.company_name : String
      Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).company_name
    rescue Partiduo::Api::NotFound
      ""
    end

    # Dossier d'un foyer (ADR-011 A3) : pas de prélèvement (D-SEPA-002).
    def self.household? : Bool
      Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).household?
    rescue Partiduo::Api::NotFound
      false
    end
  end
end
