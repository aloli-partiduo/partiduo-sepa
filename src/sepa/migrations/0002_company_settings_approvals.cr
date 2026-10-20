# SPDX-License-Identifier: AGPL-3.0-or-later

# Retrait des réglages que le cœur porte désormais (contrat 0.17.0) :
# l'identifiant créancier SEPA va à la société (`core_settings`,
# A-SEPA-2, D-SEPA-016) et la validation à une ou deux personnes au réglage
# du dossier lu par le service d'approbation (`Partiduo::Api::Approvals`,
# A-SEPA-3, D-SEPA-017).
#
# Reprise des données, en SQL sur les seules colonnes que la migration 0007
# du cœur garantit (dépendance ci-dessous) — et non par le contrat, dont les
# modèles suivent le schéma *final* du cœur : une migration rejouée plus
# tard, sur un dossier qui saute des versions, lirait des colonnes pas encore
# créées (D-SEPA-016) :
#
# * ICS : copié dans la société si elle n'en a pas ; s'il diffère de celui
#   de la société, celle-ci l'emporte et la valeur de l'extension est gardée
#   dans `legacy_creditor_identifier` (montrée à l'écran des réglages) ;
#   aucune valeur n'est perdue. Les deux ont été contrôlés par la même clé
#   modulo 97 (EPC262) à la saisie.
# * Validation : `dual` dans l'extension rend le dossier `dual` (jamais
#   l'inverse : on ne relâche pas une règle), inscrit à la piste d'audit des
#   approbations (`policy.changed`), comme le ferait `update_settings`.
# * Lots préparés selon l'ancien mécanisme (en attente d'approbation) :
#   repassés en préparation, séquences des prélèvements effacées ; les
#   préparer de nouveau les soumet au service (D-SEPA-017). Les lots
#   approuvés ou émis ne changent pas.
#
# Retour arrière : colonnes recréées, ICS et mode repris de la société (ou
# de la valeur gardée) ; les lots repassés en préparation y restent.
class Migration::Sepa::V0002 < Marten::Migration
  depends_on :sepa, "0001_create_sepa"
  depends_on :core, "0007_approvals"

  COPY_CREDITOR_IDENTIFIER = <<-SQL
    UPDATE core_settings c SET creditor_identifier = s.creditor_identifier
    FROM (SELECT upper(creditor_identifier) AS creditor_identifier FROM sepa_setting ORDER BY id LIMIT 1) s
    WHERE c.creditor_identifier = '' AND s.creditor_identifier <> ''
    SQL

  KEEP_DIFFERING_CREDITOR_IDENTIFIER = <<-SQL
    UPDATE sepa_setting s SET legacy_creditor_identifier = upper(s.creditor_identifier)
    WHERE s.creditor_identifier <> ''
      AND NOT EXISTS (SELECT 1 FROM core_settings c WHERE upper(c.creditor_identifier) = upper(s.creditor_identifier))
    SQL

  COPY_DUAL_APPROVAL = <<-SQL
    WITH changed AS (
      UPDATE core_settings SET approval_mode = 'dual'
      WHERE approval_mode <> 'dual' AND EXISTS (SELECT 1 FROM sepa_setting WHERE approval_mode = 'dual')
      RETURNING approval_reauth_minutes
    )
    INSERT INTO core_approval_event (approval_id, action, actor_id, detail, created_at)
    SELECT NULL, 'policy.changed', NULL,
           'single/' || approval_reauth_minutes || ' → dual/' || approval_reauth_minutes || ' (partiduo-sepa 0002)', now()
    FROM changed
    SQL

  UNFREEZE_PREPARED_ITEMS = <<-SQL
    UPDATE sepa_item i SET sequence_type = '', mandate_rum = '', mandate_signed_on = NULL, original_iban = ''
    FROM sepa_batch b WHERE b.id = i.batch_id AND b.status = 'prepared'
    SQL

  PREPARED_TO_DRAFT = "UPDATE sepa_batch SET status = 'draft', prepared_by_id = NULL, prepared_at = NULL WHERE status = 'prepared'"

  RESTORE_SETTINGS = <<-SQL
    UPDATE sepa_setting SET
      creditor_identifier = COALESCE(NULLIF(legacy_creditor_identifier, ''),
                                     (SELECT creditor_identifier FROM core_settings ORDER BY id LIMIT 1), ''),
      approval_mode = COALESCE((SELECT approval_mode FROM core_settings ORDER BY id LIMIT 1), 'single')
    SQL

  RESTORE_APPROVAL_CHECK = "ALTER TABLE sepa_setting ADD CONSTRAINT sepa_setting_approval_check CHECK (approval_mode IN ('single', 'dual'))"

  def plan
    add_column :sepa_setting, :legacy_creditor_identifier, :string, max_size: 35, default: ""
    execute(COPY_CREDITOR_IDENTIFIER, "SELECT 1")
    execute(KEEP_DIFFERING_CREDITOR_IDENTIFIER, "SELECT 1")
    execute(COPY_DUAL_APPROVAL, "SELECT 1")
    execute(UNFREEZE_PREPARED_ITEMS, "SELECT 1")
    execute(PREPARED_TO_DRAFT, "SELECT 1")
    execute("SELECT 1", RESTORE_APPROVAL_CHECK)
    execute("SELECT 1", RESTORE_SETTINGS)
    remove_column :sepa_setting, :creditor_identifier
    remove_column :sepa_setting, :approval_mode
  end
end
