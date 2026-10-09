# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  module Ui
    # `/ext/SEPA/mandates` : mandats de prélèvement — client, RUM, date de
    # signature, IBAN masqué, nature, séquence du prochain prélèvement,
    # expiration, statut (D-SEPA-007).
    class MandatesHandler < Handler
      def get
        columns = [
          Table::Column.new("card", I18n.t("sepa_ui.mandates.card")),
          Table::Column.new("rum", I18n.t("sepa_ui.mandates.rum"), "mono"),
          Table::Column.new("signed_on", I18n.t("sepa_ui.mandates.signed_on"), "mono"),
          Table::Column.new("iban", I18n.t("sepa_ui.mandates.iban"), "mono", secondary: true),
          Table::Column.new("kind", I18n.t("sepa_ui.mandates.kind"), secondary: true),
          Table::Column.new("sequence", I18n.t("sepa_ui.mandates.next_sequence")),
          Table::Column.new("expires_on", I18n.t("sepa_ui.mandates.expires_on"), "mono", secondary: true),
          Table::Column.new("status", I18n.t("sepa_ui.mandates.status")),
        ]
        rows = Api.mandates(actor).map do |view|
          url = can_admin? ? Ui.url("mandate_edit", id: view.id) : nil
          Table::Row.new([
            Table::Cell.new([view.card_code, view.card_name].compact.join(" · "), url),
            Table::Cell.new(view.rum, url),
            Table::Cell.new(fmt.date(view.signed_on), sort: view.signed_on.to_s("%Y-%m-%d")),
            Table::Cell.new(view.iban_masked),
            Table::Cell.new(I18n.t(view.kind_key)),
            Table::Cell.new(view.next_sequence.try { |code| I18n.t("sepa.sequences.#{code}") } || "—",
              tag: view.amended ? I18n.t("sepa_ui.mandates.amended") : nil),
            Table::Cell.new(view.expires_on.try { |date| fmt.date(date) } || "", sort: date_key(view.expires_on)),
            Table::Cell.new(I18n.t(view.status_key)),
          ], view.active? ? "" : "pd-muted")
        end
        table = Table.new(I18n.t("sepa.menu.sepa_mandates"), columns, rows, Ui.url("mandates"),
          empty_message: I18n.t("sepa_ui.mandates.none"), id: "sepa-mandates")
        actions = can_admin? ? [link_action("sepa_ui.mandates.new", Ui.url("mandate_new"), "primary", "plus")] : [] of Screen::Action
        list_page(I18n.t("sepa.menu.sepa_mandates"), table, crumbs({I18n.t("sepa.menu.sepa_mandates"), nil}),
          "sepa_ui.mandates.csv_name", actions, intro: I18n.t("sepa_ui.mandates.intro"))
      end
    end

    # Formulaire d'un mandat (création, modification).
    abstract class MandateScreen < Handler
      FIELDS = %w[card_code rum signed_on iban bic debtor_name kind]

      def submitted : Hash(String, String)
        FIELDS.to_h { |name| {name, field(name)} }
      end

      def values_of(view : Api::MandateView) : Hash(String, String)
        {"card_code" => view.card_code, "rum" => view.rum, "signed_on" => view.signed_on.to_s("%F"),
         "iban" => Api.format_iban(view.iban), "bic" => view.bic, "debtor_name" => view.debtor_name, "kind" => view.kind}
      end

      def mandate_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        fields = [
          Form::Field.new("card_code", I18n.t("sepa_ui.mandates.card"), value: value.call("card_code"), required: true,
            mono: true, maxlength: 64, help: I18n.t("sepa_ui.mandates.card_help")),
          Form::Field.new("rum", I18n.t("sepa_ui.mandates.rum"), value: value.call("rum"), mono: true, maxlength: 35,
            help: I18n.t("sepa_ui.mandates.rum_help")),
          Form::Field.new("signed_on", I18n.t("sepa_ui.mandates.signed_on"), "date", value.call("signed_on"), required: true),
          Form::Field.new("kind", I18n.t("sepa_ui.mandates.kind"), "select", value.call("kind"),
            options: code_options(Api::MANDATE_KINDS, "sepa.mandate_kinds")),
          Form::Field.new("debtor_name", I18n.t("sepa_ui.mandates.debtor_name"), value: value.call("debtor_name"), maxlength: 70,
            help: I18n.t("sepa_ui.mandates.debtor_name_help")),
          Form::Field.new("iban", I18n.t("sepa_ui.mandates.iban"), value: value.call("iban"), required: true, mono: true,
            maxlength: 42),
          Form::Field.new("bic", I18n.t("sepa_ui.mandates.bic"), value: value.call("bic"), mono: true, maxlength: 11,
            help: I18n.t("sepa_ui.mandates.bic_help")),
        ]
        Form.new([Form::Group.new(nil, fields)])
      end

      def read_input(form : Form) : Api::MandateInput?
        date = fmt.parse_date(field("signed_on"))
        form.add_error("signed_on", I18n.t("ui.forms.invalid_date")) if date.nil?
        return if form.invalid || date.nil?
        Api::MandateInput.new(card_code: field("card_code"), signed_on: date, iban: field("iban"), rum: field("rum"),
          bic: field("bic"), debtor_name: field("debtor_name"), kind: field("kind").presence || "recurrent")
      end

      def mandate_crumbs(title : String) : Array(Screen::Crumb)
        crumbs({I18n.t("sepa.menu.sepa_mandates"), Ui.url("mandates")}, {title, nil})
      end
    end

    class MandateNewHandler < MandateScreen
      def get
        show(mandate_form({"kind" => "recurrent", "card_code" => query("card")}))
      end

      def post
        form = mandate_form(submitted)
        if input = read_input(form)
          result = Api.create_mandate(actor, input)
          if result.success?
            flash["success"] = I18n.t("sepa_ui.flash.mandate_saved", rum: result.value!.rum)
            return go(Ui.url("mandates"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("sepa_ui.mandates.new")
        form_page(title, mandate_crumbs(title), form, Ui.url("mandate_new"), I18n.t("ui.forms.create"), Ui.url("mandates"),
          intro: I18n.t("sepa_ui.mandates.form_intro"))
      end
    end

    class MandateEditHandler < MandateScreen
      def get
        view = Api.mandate(actor, id_param)
        show(view, mandate_form(values_of(view)))
      end

      def post
        view = Api.mandate(actor, id_param)
        form = mandate_form(submitted)
        if input = read_input(form)
          result = Api.update_mandate(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("sepa_ui.flash.mandate_saved", rum: result.value!.rum)
            return go(Ui.url("mandates"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::MandateView, form : Form) : Marten::HTTP::Response
        actions = [] of Screen::Action
        if view.active?
          actions << post_action("sepa_ui.mandates.revoke", Ui.url("mandate_revoke", id: view.id), "sepa_ui.mandates.revoke_confirm", "danger", "x")
        end
        unless view.in_use
          actions << post_action("sepa_ui.mandates.delete", Ui.url("mandate_delete", id: view.id), "sepa_ui.mandates.delete_confirm", "danger", "trash-2")
        end
        intro = I18n.t("sepa_ui.mandates.summary", count: view.collection_count, status: I18n.t(view.status_key))
        form_page(view.rum, mandate_crumbs(view.rum), view.active? ? form : nil, Ui.url("mandate_edit", id: view.id),
          I18n.t("ui.forms.save"), Ui.url("mandates"), actions, intro: intro)
      end
    end

    class MandateRevokeHandler < Handler
      def get
        go(Ui.url("mandates"))
      end

      def post
        after(Api.revoke_mandate(actor, id_param), "sepa_ui.flash.mandate_revoked", Ui.url("mandates"))
      end
    end

    class MandateDeleteHandler < Handler
      def get
        go(Ui.url("mandates"))
      end

      def post
        after(Api.delete_mandate(actor, id_param), "sepa_ui.flash.mandate_deleted", Ui.url("mandates"))
      end
    end
  end
end
