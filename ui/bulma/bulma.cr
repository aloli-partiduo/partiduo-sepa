# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension des paiements SEPA (ADR-005 D4) : lots
# (liste, composition depuis les écritures ouvertes, correction des
# paiements en HTMX, préparation, approbation, fichier, émission,
# règlements), mandats de prélèvement, réglages. Montée par
# `partiduo-ui-bulma` sous `/ext/SEPA/` (ADR-003 D3). La distribution la
# requiert après l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-sepa"
# require "partiduo-sepa/ui/bulma"
# ```
#
# puis ajoute `Sepa::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Sepa::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle
# d'accès est fait par l'interface, avant le handler, à partir du montage,
# puis par le contrat.
require "../../src/partiduo-sepa"

require "./presenters"
require "./handlers/base"
require "./handlers/**"
require "./dashboard_tile"

module Sepa
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/sepa/`), fichiers statiques (`assets/sepa/`) et libellés
    # d'écran (`locales/`, clés `sepa_ui.*`).
    class App < Marten::App
      label "sepa_ui"
    end

    INSTALLED_APPS = [Sepa::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/SEPA/`, nommées `sepa:<nom>` : celles que
    # citent les menus du manifeste.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Sepa::Ui::IndexHandler, name: "index"
      path "/batches", Sepa::Ui::BatchesHandler, name: "batches"
      path "/batches/new", Sepa::Ui::BatchNewHandler, name: "batch_new"
      path "/batches/<id:int>", Sepa::Ui::BatchHandler, name: "batch"
      path "/batches/<id:int>/edit", Sepa::Ui::BatchEditHandler, name: "batch_edit"
      path "/batches/<id:int>/add", Sepa::Ui::BatchAddHandler, name: "batch_add"
      path "/batches/<id:int>/item", Sepa::Ui::ItemNewHandler, name: "item_new"
      path "/batches/<id:int>/prepare", Sepa::Ui::BatchPrepareHandler, name: "batch_prepare"
      path "/batches/<id:int>/approve", Sepa::Ui::BatchApproveHandler, name: "batch_approve"
      path "/batches/<id:int>/reopen", Sepa::Ui::BatchReopenHandler, name: "batch_reopen"
      path "/batches/<id:int>/delete", Sepa::Ui::BatchDeleteHandler, name: "batch_delete"
      path "/batches/<id:int>/issue", Sepa::Ui::BatchIssueHandler, name: "batch_issue"
      path "/batches/<id:int>/settle", Sepa::Ui::BatchSettleHandler, name: "batch_settle"
      path "/batches/<id:int>/file", Sepa::Ui::BatchFileHandler, name: "batch_file"
      path "/items/<id:int>", Sepa::Ui::ItemHandler, name: "item"
      path "/items/<id:int>/remove", Sepa::Ui::ItemRemoveHandler, name: "item_remove"
      path "/mandates", Sepa::Ui::MandatesHandler, name: "mandates"
      path "/mandates/new", Sepa::Ui::MandateNewHandler, name: "mandate_new"
      path "/mandates/<id:int>", Sepa::Ui::MandateEditHandler, name: "mandate_edit"
      path "/mandates/<id:int>/revoke", Sepa::Ui::MandateRevokeHandler, name: "mandate_revoke"
      path "/mandates/<id:int>/delete", Sepa::Ui::MandateDeleteHandler, name: "mandate_delete"
      path "/settings", Sepa::Ui::SettingsHandler, name: "settings"
    end

    # Routes qui composent un lot : `sepa.prepare` ; qui l'approuvent,
    # l'émettent ou passent les règlements : `sepa.approve` ; réglages et
    # mandats : `sepa.admin` ; les autres : `sepa.read`. Le contrat vérifie
    # encore les permissions du cœur (pièce jointe, écritures).
    PREPARE_ROUTES = %w[batch_new batch_edit batch_add item_new item item_remove batch_prepare batch_reopen batch_delete]
    APPROVE_ROUTES = %w[batch_approve batch_issue batch_settle]
    ADMIN_ROUTES   = %w[mandate_new mandate_edit mandate_revoke mandate_delete settings]
  end
end

PartiduoUi::Extensions.mount Sepa::CODE, Sepa::Ui::ROUTES, permission: Sepa::Api::READ,
  permissions: Sepa::Ui::PREPARE_ROUTES.to_h { |route| {route, Sepa::Api::PREPARE} }
    .merge(Sepa::Ui::APPROVE_ROUTES.to_h { |route| {route, Sepa::Api::APPROVE} })
    .merge(Sepa::Ui::ADMIN_ROUTES.to_h { |route| {route, Sepa::Api::ADMIN} })

# Compteur du menu « Lots de paiements » et ligne de « À traiter » du
# tableau de bord : lots à approuver ou à émettre, pour qui approuve.
PartiduoUi::Extensions.counter("SEPA_BATCHES", route: "sepa:batches", todo: "sepa_ui.todo", tone: "warn") do |actor|
  Sepa::Api.pending_count(actor)
end
