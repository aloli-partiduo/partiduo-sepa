# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Mandat de prélèvement SEPA Core signé par un client (D-SEPA-007) :
  # fiche du débiteur (`card_code`, relue par le contrat, sans clé
  # étrangère), référence unique du mandat (RUM), date de signature, nom,
  # IBAN et BIC du débiteur, mandat récurrent ou ponctuel.
  #
  # * `status` : `active`, `revoked` (révoqué à `revoked_on`), `used`
  #   (mandat ponctuel déjà prélevé) ;
  # * `collection_count`, `last_collected_on` : prélèvements émis ; la
  #   séquence du prochain en découle (FRST, RCUR, OOFF) ;
  # * `original_iban` : IBAN d'avant une modification survenue après un
  #   premier prélèvement, signalé à la banque au suivant (amendement du
  #   mandat), puis effacé.
  #
  # Interne.
  class Mandate < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :card_code, :string, max_size: 64, index: true
    field :rum, :string, max_size: 35
    field :signed_on, :date
    field :debtor_name, :string, max_size: 70
    field :iban, :string, max_size: 34
    field :bic, :string, max_size: 11, blank: true, default: ""
    field :kind, :string, max_size: 12, default: "recurrent"
    field :status, :string, max_size: 8, default: "active"
    field :revoked_on, :date, blank: true, null: true
    field :original_iban, :string, max_size: 34, blank: true, default: ""
    field :collection_count, :int, default: 0
    field :last_collected_on, :date, blank: true, null: true
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
