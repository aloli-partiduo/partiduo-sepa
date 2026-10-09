# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension des paiements SEPA : réglages, mandats de
# prélèvement, lots et paiements.
#
# Intégrité en base : genres, statuts, modes et séquences contrôlés ;
# montant d'un paiement strictement positif (colonne au centime) ; un lot
# approuvé ou émis porte son fichier et son identifiant de message, un lot
# émis sa date d'émission ; en validation à deux, l'approbateur n'est pas
# celui qui a préparé ; un règlement passé porte son écriture ; une
# écriture ouverte n'est réglée que par un seul paiement vivant ; une RUM
# n'est donnée qu'une fois. Les liens vers le cœur (journal, écriture,
# ligne d'écriture, pièce jointe, fiche) sont des identifiants relus par le
# contrat, sans clé étrangère (D-SEPA-003).
class Migration::Sepa::V0001 < Marten::Migration
  depends_on :auth, "0001_create_auth_user_table"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE sepa_setting
        ADD CONSTRAINT sepa_setting_approval_check CHECK (approval_mode IN ('single', 'dual')),
        ADD CONSTRAINT sepa_setting_settlement_check CHECK (settlement_mode IN ('post', 'propose'))
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE sepa_mandate
        ADD CONSTRAINT sepa_mandate_kind_check CHECK (kind IN ('recurrent', 'one_off')),
        ADD CONSTRAINT sepa_mandate_status_check CHECK (status IN ('active', 'revoked', 'used')),
        ADD CONSTRAINT sepa_mandate_revoked_check CHECK ((status = 'revoked') = (revoked_on IS NOT NULL)),
        ADD CONSTRAINT sepa_mandate_rum_check CHECK (btrim(rum) <> '' AND rum !~ '(^/|/$|//)'),
        ADD CONSTRAINT sepa_mandate_iban_check CHECK (iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'),
        ADD CONSTRAINT sepa_mandate_count_check CHECK (collection_count >= 0),
        ADD CONSTRAINT sepa_mandate_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {"CREATE UNIQUE INDEX sepa_mandate_rum_unique ON sepa_mandate (upper(rum))",
     "DROP INDEX IF EXISTS sepa_mandate_rum_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE sepa_batch
        ADD CONSTRAINT sepa_batch_kind_check CHECK (kind IN ('transfer', 'debit')),
        ADD CONSTRAINT sepa_batch_status_check CHECK (status IN ('draft', 'prepared', 'approved', 'issued')),
        ADD CONSTRAINT sepa_batch_file_check CHECK (status NOT IN ('approved', 'issued')
          OR (attachment_id IS NOT NULL AND message_id <> '' AND approved_by_id IS NOT NULL)),
        ADD CONSTRAINT sepa_batch_prepared_check CHECK (status = 'draft' OR prepared_by_id IS NOT NULL),
        ADD CONSTRAINT sepa_batch_issued_check CHECK ((status = 'issued') = (issued_on IS NOT NULL)),
        ADD CONSTRAINT sepa_batch_dual_check CHECK (approval_mode <> 'dual' OR approved_by_id IS DISTINCT FROM prepared_by_id),
        ADD CONSTRAINT sepa_batch_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id),
        ADD CONSTRAINT sepa_batch_prepared_by_fk FOREIGN KEY (prepared_by_id) REFERENCES auth_user (id),
        ADD CONSTRAINT sepa_batch_approved_by_fk FOREIGN KEY (approved_by_id) REFERENCES auth_user (id),
        ADD CONSTRAINT sepa_batch_issued_by_fk FOREIGN KEY (issued_by_id) REFERENCES auth_user (id)
      SQL
    {"CREATE UNIQUE INDEX sepa_batch_message_unique ON sepa_batch (message_id) WHERE message_id <> ''",
     "DROP INDEX IF EXISTS sepa_batch_message_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE sepa_item
        ADD CONSTRAINT sepa_item_amount_check CHECK (amount > 0),
        ADD CONSTRAINT sepa_item_sequence_check CHECK (sequence_type IN ('', 'FRST', 'RCUR', 'OOFF')),
        ADD CONSTRAINT sepa_item_settlement_check CHECK (settlement IN ('none', 'posted', 'elsewhere')),
        ADD CONSTRAINT sepa_item_posted_check CHECK ((settlement = 'posted') = (settlement_entry_id IS NOT NULL)),
        ADD CONSTRAINT sepa_item_card_check CHECK (btrim(card_code) <> ''),
        ADD CONSTRAINT sepa_item_batch_fk FOREIGN KEY (batch_id) REFERENCES sepa_batch (id) ON DELETE CASCADE,
        ADD CONSTRAINT sepa_item_mandate_fk FOREIGN KEY (mandate_id) REFERENCES sepa_mandate (id) ON DELETE RESTRICT
      SQL
    {"CREATE UNIQUE INDEX sepa_item_line_unique ON sepa_item (entry_line_id) " \
     "WHERE entry_line_id IS NOT NULL AND settlement <> 'elsewhere'", "DROP INDEX IF EXISTS sepa_item_line_unique"},
  ]

  def plan
    create_table :sepa_setting do
      column :id, :big_int, primary_key: true, auto: true
      column :approval_mode, :string, max_size: 8, default: "single"
      column :settlement_mode, :string, max_size: 8, default: "post"
      column :batch_booking, :bool, default: true
      column :creditor_identifier, :string, max_size: 35, default: ""
      column :ledger_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :sepa_mandate do
      column :id, :big_int, primary_key: true, auto: true
      column :card_code, :string, max_size: 64, index: true
      column :rum, :string, max_size: 35
      column :signed_on, :date
      column :debtor_name, :string, max_size: 70
      column :iban, :string, max_size: 34
      column :bic, :string, max_size: 11, default: ""
      column :kind, :string, max_size: 12, default: "recurrent"
      column :status, :string, max_size: 8, default: "active"
      column :revoked_on, :date, null: true
      column :original_iban, :string, max_size: 34, default: ""
      column :collection_count, :int, default: 0
      column :last_collected_on, :date, null: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :sepa_batch do
      column :id, :big_int, primary_key: true, auto: true
      column :kind, :string, max_size: 8
      column :ledger_id, :big_int, index: true
      column :status, :string, max_size: 8, default: "draft"
      column :label, :string, max_size: 140, default: ""
      column :requested_on, :date
      column :batch_booking, :bool, default: true
      column :message_id, :string, max_size: 35, default: ""
      column :attachment_id, :big_int, null: true
      column :file_sha256, :string, max_size: 64, default: ""
      column :approval_mode, :string, max_size: 8, default: ""
      column :created_by_id, :big_int, null: true
      column :prepared_by_id, :big_int, null: true
      column :prepared_at, :date_time, null: true
      column :approved_by_id, :big_int, null: true
      column :approved_at, :date_time, null: true
      column :issued_by_id, :big_int, null: true
      column :issued_at, :date_time, null: true
      column :issued_on, :date, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :sepa_item do
      column :id, :big_int, primary_key: true, auto: true
      column :batch_id, :big_int, index: true
      column :position, :int, default: 0
      column :card_code, :string, max_size: 64
      column :name, :string, max_size: 70
      column :iban, :string, max_size: 34, default: ""
      column :bic, :string, max_size: 11, default: ""
      column :amount, :decimal, max_digits: 20, decimal_places: 2
      column :remittance, :string, max_size: 140, default: ""
      column :end_to_end_id, :string, max_size: 35, default: ""
      column :entry_line_id, :big_int, null: true
      column :entry_id, :big_int, null: true
      column :receipt, :string, max_size: 40, default: ""
      column :due_on, :date, null: true
      column :mandate_id, :big_int, null: true, index: true
      column :sequence_type, :string, max_size: 4, default: ""
      column :mandate_rum, :string, max_size: 35, default: ""
      column :mandate_signed_on, :date, null: true
      column :original_iban, :string, max_size: 34, default: ""
      column :settlement, :string, max_size: 12, default: "none"
      column :settlement_entry_id, :big_int, null: true, index: true
      column :reversed_entry_id, :big_int, null: true
      column :error_key, :string, max_size: 200, default: ""
      column :error_params, :text, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
