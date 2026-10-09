# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Lot de paiements SEPA (D-SEPA-003) : virements (`transfer`, pain.001)
  # ou prélèvements (`debit`, pain.008), depuis le compte bancaire d'un
  # journal financier (`ledger_id`, relu par le contrat), à la date
  # d'exécution ou d'échéance demandée (`requested_on`).
  #
  # * `status` : `draft` (composé), `prepared` (contrôlé et figé, en attente
  #   d'approbation), `approved` (fichier produit et conservé), `issued`
  #   (émission confirmée par l'utilisateur, `issued_on`) ;
  # * `message_id`, `attachment_id`, `file_sha256` : fichier ISO 20022
  #   produit à l'approbation, conservé par le socle (sans clé étrangère) ;
  # * `approval_mode` : mode de validation appliqué (`single`, `dual`),
  #   figé à l'approbation (D-SEPA-005).
  #
  # Interne.
  class Batch < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :kind, :string, max_size: 8
    field :ledger_id, :big_int, index: true
    field :status, :string, max_size: 8, default: "draft"
    field :label, :string, max_size: 140, blank: true, default: ""
    field :requested_on, :date
    field :batch_booking, :bool, default: true
    field :message_id, :string, max_size: 35, blank: true, default: ""
    field :attachment_id, :big_int, blank: true, null: true
    field :file_sha256, :string, max_size: 64, blank: true, default: ""
    field :approval_mode, :string, max_size: 8, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true
    field :prepared_by_id, :big_int, blank: true, null: true
    field :prepared_at, :date_time, blank: true, null: true
    field :approved_by_id, :big_int, blank: true, null: true
    field :approved_at, :date_time, blank: true, null: true
    field :issued_by_id, :big_int, blank: true, null: true
    field :issued_at, :date_time, blank: true, null: true
    field :issued_on, :date, blank: true, null: true

    with_timestamp_fields
  end
end
