# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Réglages du dossier propres à l'extension (une ligne au plus ; à défaut,
  # les valeurs par défaut) : règlement passé à la confirmation de l'émission
  # ou seulement proposé (D-SEPA-010), comptabilisation groupée demandée à la
  # banque, journal financier proposé. L'identifiant créancier SEPA et la
  # validation à une ou deux personnes sont ceux de la société
  # (D-SEPA-016, D-SEPA-017).
  #
  # `legacy_creditor_identifier` : ICS des réglages de l'extension d'avant
  # 0.1.3, gardé par la migration 0002 seulement s'il diffère de celui de la
  # société (qui l'emporte) ; jamais lu pour produire un fichier. Interne.
  class Setting < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :settlement_mode, :string, max_size: 8, default: "post"
    field :batch_booking, :bool, default: true
    field :ledger_id, :big_int, blank: true, null: true
    field :legacy_creditor_identifier, :string, max_size: 35, blank: true, default: ""

    with_timestamp_fields
  end
end
