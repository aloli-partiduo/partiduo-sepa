# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  module Ui
    # Tuile « Paiements SEPA » des tableaux de bord du dossier : lots à
    # approuver, lots approuvés à émettre, règlements à passer. Rien si
    # rien n'attend, si l'extension est inactive ou l'acteur sans droit.
    module Tile
      def self.for(actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) : PartiduoUi::Dashboard::Tile?
        view = Api.tile(actor) || return
        waiting = view.to_approve + view.to_issue
        return if waiting.zero? && view.to_settle.zero?
        PartiduoUi::Dashboard::Tile.new(Sepa::CODE, I18n.t("sepa_ui.tile.label"), waiting.to_s,
          sub: I18n.t("sepa_ui.tile.sub", count: view.to_approve, issue: view.to_issue),
          alert: view.to_settle.zero? ? nil : I18n.t("sepa_ui.tile.to_settle", count: view.to_settle),
          url: Ui.url("batches"))
      end
    end
  end
end

# Point d'accroche de l'interface commune (`PartiduoUi::Extensions.tile`) :
# appelé seulement quand l'extension est active.
PartiduoUi::Extensions.tile Sepa::CODE do |actor, fmt|
  Sepa::Ui::Tile.for(actor, fmt).try { |tile| [tile] } || [] of PartiduoUi::Dashboard::Tile
end
