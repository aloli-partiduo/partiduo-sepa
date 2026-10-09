# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  module Ui
    # Base des écrans de l'extension, sur celle des écrans du référentiel de
    # l'interface (listes, formulaires des gabarits `ui/reference/*.html`) :
    # fil d'Ariane « Paiements SEPA › … », listes de choix, lecture des
    # champs. L'accès a déjà été contrôlé par `PartiduoUi::ExtensionHandler`
    # à partir du montage ; `Sepa::Api` vérifie encore la permission de
    # chaque commande.
    abstract class Handler < PartiduoUi::ReferenceHandler
      alias Api = Sepa::Api
      alias Acc = Partiduo::Api::Accounting
      alias Form = PartiduoUi::Form
      alias Table = PartiduoUi::Table
      alias Screen = PartiduoUi::Screen

      def actor : Partiduo::Api::Actor
        current.actor
      end

      def crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("sepa.menu.sepa")]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def settings_crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("core.menu.settings")]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def can_prepare? : Bool
        can?(Api::PREPARE)
      end

      def can_approve? : Bool
        can?(Api::APPROVE)
      end

      def can_admin? : Bool
        can?(Api::ADMIN)
      end

      @ledgers : Array(Acc::LedgerView)?

      # Journaux financiers ouverts à l'acteur.
      def ledgers : Array(Acc::LedgerView)
        @ledgers ||= begin
          Acc.ledgers(actor, Acc::LedgerKind::Financial, enabled_only: true)
        rescue Partiduo::Api::AccessDenied
          [] of Acc::LedgerView
        end
      end

      # --- Lecture des champs ---------------------------------------------------------

      def id_field(name : String) : Int64?
        field(name).to_i64?
      end

      # Identifiants cochés (`ids`, répété).
      def checked_ids : Array(Int64)
        values = request.data.fetch_all("ids", [] of String) || [] of String
        values.compact_map(&.to_s.to_i64?).uniq!
      end

      # --- Listes de choix -------------------------------------------------------------

      def ledger_options(blank : Bool = false) : Array(Form::Option)
        list = ledgers.map { |ledger| option(ledger.id.to_s, "#{ledger.code} · #{ledger.name}") }
        blank ? [option("", I18n.t("sepa_ui.forms.none"))] + list : list
      end

      def code_options(codes : Array(String), scope : String) : Array(Form::Option)
        codes.map { |code| option(code, I18n.t("#{scope}.#{code}")) }
      end

      def messages(result) : String
        result.errors.map { |error| fmt.message(error) }.join(" ")
      end

      # Redirection après une commande, avec le message du résultat.
      def after(result, success_key : String, url : String, params = {} of String => String) : Marten::HTTP::Response
        if result.success?
          flash["success"] = I18n.t(success_key, params)
        else
          flash["danger"] = messages(result)
        end
        go(url)
      end

      # Retour sûr (`next`), à défaut l'adresse donnée.
      def back(default : String) : String
        PartiduoUi::Navigation.safe_path(field("next").presence || query("next").presence) || default
      end

      # Datalist des fiches d'une nature (`supplier`, `customer`) ; rien si
      # l'acteur ne peut pas les lire.
      def card_list(kind : String) : Array(Row)
        Partiduo::Api::Cards.cards(actor, Partiduo::Api::Cards::CardQuery.new(kind: kind, limit: 1000)).map do |card|
          Ui.row({"value" => card.code, "label" => card.name})
        end
      rescue Partiduo::Api::AccessDenied
        [] of Row
      end
    end

    # `/ext/SEPA/` : les lots.
    class IndexHandler < Handler
      def get
        go(Ui.url("batches"))
      end
    end
  end
end
