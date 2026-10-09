# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension des paiements SEPA (ADR-003 D2).
#
# * Dépendance : `ACCOUNTING` — les lots sont tirés des écritures ouvertes
#   (factures fournisseurs, factures clients), et les règlements passent par
#   le service d'écriture du module, dans le journal financier du compte
#   donneur d'ordre.
# * Aucune incompatibilité : un foyer peut aussi grouper ses virements
#   (D-SEPA-002) ; les prélèvements exigent un identifiant créancier SEPA,
#   qu'un foyer n'a pas.
# * Permissions (D4) : `sepa.read` (lots, mandats, fichiers), `sepa.prepare`
#   (composer un lot, le préparer, le rouvrir, le supprimer),
#   `sepa.approve` (approuver et produire le fichier, confirmer l'émission,
#   passer les règlements), `sepa.admin` (réglages, mandats). Le contrat du
#   cœur exige en plus ses propres droits : `core.attachment.write` pour
#   conserver le fichier, `accounting.entry.read` pour lire les écritures
#   ouvertes, `accounting.entry.post` et l'écriture dans le journal pour
#   passer les règlements (D-SEPA-004).
# * Menu (D6 d'ADR-003) : rubrique « Paiements SEPA » après les relevés
#   bancaires ; réglages sous « Paramètres ».
# * Abonnement : `entry.cancelled` — un règlement extourné rend sa ligne à
#   passer (D-SEPA-011).
Partiduo::Modules.register do
  code "SEPA"
  name "sepa.module.name"
  version Sepa::VERSION
  requires_core "~> 0.1"
  depends_on "ACCOUNTING"

  permission "sepa.read"
  permission "sepa.prepare"
  permission "sepa.approve"
  permission "sepa.admin"

  menu "SEPA", order: 36, permission: "sepa.read"
  menu "SEPA_BATCHES", parent: "SEPA", order: 10, route: "sepa:batches", permission: "sepa.read"
  menu "SEPA_NEW", parent: "SEPA", order: 20, route: "sepa:batch_new", permission: "sepa.prepare"
  menu "SEPA_MANDATES", parent: "SEPA", order: 30, route: "sepa:mandates", permission: "sepa.read"
  menu "SEPA_SETTINGS", parent: "SETTINGS", order: 96, route: "sepa:settings", permission: "sepa.admin"

  ui "bulma", path: "ui/bulma"

  on("entry.cancelled") { |event| Sepa::Subscriptions.entry_cancelled(event) }
end
