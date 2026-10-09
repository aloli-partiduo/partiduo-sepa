# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Réglages du dossier (une ligne au plus ; à défaut, les valeurs par
  # défaut) : validation à une ou deux personnes (D-SEPA-005), règlement
  # passé à la confirmation de l'émission ou seulement proposé
  # (D-SEPA-010), comptabilisation groupée demandée à la banque, identifiant
  # créancier SEPA des prélèvements, journal financier proposé. Interne.
  class Setting < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :approval_mode, :string, max_size: 8, default: "single"
    field :settlement_mode, :string, max_size: 8, default: "post"
    field :batch_booking, :bool, default: true
    field :creditor_identifier, :string, max_size: 35, blank: true, default: ""
    field :ledger_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
