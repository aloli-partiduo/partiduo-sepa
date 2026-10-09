# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-sepa` : le métier de l'extension des
# paiements SEPA (manifeste, modèles, contrôles, production des fichiers
# ISO 20022, abonnements, contrat `Sepa::Api`), sans interface. L'interface
# Bulma est dans `ui/bulma/`, requise à part par la distribution :
# `require "partiduo-sepa/ui/bulma"`.
#
# La distribution ajoute ensuite `Sepa::INSTALLED_APPS` à ses applications
# Marten, et `require "partiduo-sepa/cli"` à sa ligne de commande
# (migrations).
require "partiduo"

require "./sepa/app"
