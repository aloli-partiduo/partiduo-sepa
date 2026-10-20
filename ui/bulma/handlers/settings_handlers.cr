# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  module Ui
    # `/ext/SEPA/settings` : réglages (`sepa.admin`) — règlement passé ou
    # proposé à l'émission, comptabilisation groupée, journal proposé.
    # L'identifiant créancier SEPA et la validation à une ou deux personnes
    # sont ceux de la société (écran « Société » de l'interface,
    # D-SEPA-016, D-SEPA-017) : rappelés ici, avec un lien vers lui.
    class SettingsHandler < Handler
      FIELDS = %w[settlement_mode batch_booking ledger_id discard_legacy_creditor_identifier]

      def get
        view = Api.settings(actor)
        show(view, settings_form(view, {"settlement_mode" => view.settlement_mode,
                                        "batch_booking"   => view.batch_booking ? "1" : "",
                                        "ledger_id"       => view.ledger_id.to_s}))
      end

      def post
        view = Api.settings(actor)
        form = settings_form(view, FIELDS.to_h { |name| {name, field(name)} })
        input = Api::SettingsInput.new(settlement_mode: field("settlement_mode"), batch_booking: checkbox("batch_booking"),
          ledger_id: id_field("ledger_id"), discard_legacy_creditor_identifier: checkbox("discard_legacy_creditor_identifier"))
        result = Api.update_settings(actor, input)
        if result.success?
          flash["success"] = I18n.t("sepa_ui.flash.saved")
          return go(Ui.url("settings"))
        end
        form.add_errors(result.errors, fmt)
        show(view, form)
      end

      private def settings_form(view : Api::SettingsView, values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        settlement = [
          Form::Field.new("settlement_mode", I18n.t("sepa_ui.settings.settlement_mode"), "select", value.call("settlement_mode"),
            options: code_options(Api::SETTLEMENT_MODES, "sepa.settlement_modes"), help: I18n.t("sepa_ui.settings.settlement_help")),
        ]
        bank = [
          Form::Field.new("ledger_id", I18n.t("sepa_ui.settings.ledger"), "select", value.call("ledger_id"),
            options: ledger_options(blank: true)),
          Form::Field.new("batch_booking", I18n.t("sepa_ui.batches.batch_booking"), "checkbox", value.call("batch_booking"),
            help: I18n.t("sepa_ui.batches.batch_booking_help")),
        ]
        legacy = view.legacy_creditor_identifier
        unless legacy.empty?
          bank << Form::Field.new("discard_legacy_creditor_identifier",
            I18n.t("sepa_ui.settings.legacy_discard", ics: legacy), "checkbox", value.call("discard_legacy_creditor_identifier"),
            help: I18n.t("sepa_ui.settings.legacy_help", ics: legacy,
              company: view.creditor_identifier.presence || I18n.t("sepa_ui.settings.company_ics_blank")))
        end
        Form.new([Form::Group.new(I18n.t("sepa_ui.settings.validation"), settlement), Form::Group.new(I18n.t("sepa_ui.settings.bank"), bank)])
      end

      private def show(view : Api::SettingsView, form : Form) : Marten::HTTP::Response
        title = I18n.t("sepa.menu.sepa_settings")
        intro = I18n.t("sepa_ui.settings.intro_company",
          ics: view.creditor_identifier.presence || I18n.t("sepa_ui.settings.company_ics_blank"),
          mode: I18n.t("sepa.approval_modes.#{view.approval_mode}"))
        actions = [] of Screen::Action
        if can?("core.settings.manage")
          actions << link_action("sepa_ui.settings.company", Marten.routes.reverse("core:company_edit"), "", "settings")
        end
        form_page(title, settings_crumbs({title, nil}), form, Ui.url("settings"), I18n.t("ui.forms.save"), nil,
          actions: actions, intro: intro)
      end
    end
  end
end
