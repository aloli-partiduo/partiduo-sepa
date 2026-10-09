# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Paiement d'un lot (D-SEPA-003) : tiers (fiche), nom, IBAN et BIC de sa
  # banque, montant exact, communication, référence de bout en bout.
  #
  # * `entry_line_id`, `entry_id`, `receipt`, `due_on` : écriture ouverte
  #   réglée (facture fournisseur pour un virement, facture client pour un
  #   prélèvement), lettrée au règlement ; nuls pour un paiement saisi ;
  # * `mandate_id` : mandat d'un prélèvement ; `sequence_type`,
  #   `mandate_rum`, `mandate_signed_on`, `original_iban` figés à la
  #   préparation (FRST, RCUR, OOFF ; amendement de l'IBAN) ;
  # * `settlement` : `none` (règlement à passer), `posted`
  #   (`settlement_entry_id`), `elsewhere` (l'écriture ouverte a été
  #   lettrée hors du lot : rien n'est passé, D-SEPA-010) ;
  # * `error_key`, `error_params` : refus du dernier passage du règlement ;
  # * `reversed_entry_id` : règlement passé puis extourné (D-SEPA-011).
  #
  # Interne.
  class Item < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :batch_id, :big_int, index: true
    field :position, :int, default: 0
    field :card_code, :string, max_size: 64
    field :name, :string, max_size: 70
    field :iban, :string, max_size: 34, blank: true, default: ""
    field :bic, :string, max_size: 11, blank: true, default: ""
    field :amount, :decimal, max_digits: 20, decimal_places: 2
    field :remittance, :string, max_size: 140, blank: true, default: ""
    field :end_to_end_id, :string, max_size: 35, blank: true, default: ""
    field :entry_line_id, :big_int, blank: true, null: true
    field :entry_id, :big_int, blank: true, null: true
    field :receipt, :string, max_size: 40, blank: true, default: ""
    field :due_on, :date, blank: true, null: true
    field :mandate_id, :big_int, blank: true, null: true, index: true
    field :sequence_type, :string, max_size: 4, blank: true, default: ""
    field :mandate_rum, :string, max_size: 35, blank: true, default: ""
    field :mandate_signed_on, :date, blank: true, null: true
    field :original_iban, :string, max_size: 34, blank: true, default: ""
    field :settlement, :string, max_size: 12, default: "none"
    field :settlement_entry_id, :big_int, blank: true, null: true, index: true
    field :reversed_entry_id, :big_int, blank: true, null: true
    field :error_key, :string, max_size: 200, blank: true, default: ""
    field :error_params, :text, blank: true, default: ""

    with_timestamp_fields

    before_validation :normalize_amount

    # Un montant relu de PostgreSQL peut porter plus de décimales nulles
    # que la colonne (`300.6000`) : ramené au centime s'il y tient, refusé
    # sinon par la validation du champ.
    private def normalize_amount : Nil
      value = amount || return
      rounded = value.round(2)
      self.amount = rounded if rounded == value
    end
  end
end
