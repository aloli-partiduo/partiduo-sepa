# SPDX-License-Identifier: AGPL-3.0-or-later

require "xml"

require "./manifest"
require "./models/**"
require "./services/**"
require "./xml/**"
require "./api/**"

# Extension des paiements SEPA de Partiduo : lots de virements fournisseurs
# (pain.001.001.09) et de prélèvements SDD Core (pain.008.001.08) tirés des
# écritures ouvertes de la Comptabilité, mandats de prélèvement, double
# validation facultative, fichier ISO 20022 contrôlé puis conservé en pièce
# jointe, règlements passés par `Partiduo::Api::Accounting.post_financial`.
# Aucun envoi à la banque : le fichier est déposé par l'utilisateur. Même
# plan qu'une application du cœur (DECISIONS C1 du cœur) : `manifest.cr`,
# `models/`, `migrations/`, `services/` et `xml/` (internes), `api/`
# (contrat public `Sepa::Api`), `locales/`.
module Sepa
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Code du registre (ADR-003 D2) : `sepa` dans `PARTIDUO_MODULES`.
  CODE = "SEPA"

  # Application Marten du métier : modèles (tables `sepa_*`), migrations et
  # libellés.
  class App < Marten::App
    label "sepa"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Partiduo::INSTALLED_APPS`.
  INSTALLED_APPS = [Sepa::App] of Marten::Apps::Config.class
end
