# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  module Ui
    # `/ext/SEPA/settings` : réglages (`sepa.admin`) — validation à une ou
    # deux personnes, règlement passé ou proposé à l'émission,
    # comptabilisation groupée, identifiant créancier SEPA, journal proposé.
    class SettingsHandler < Handler
      FIELDS = %w[approval_mode settlement_mode batch_booking creditor_identifier ledger_id]

      def get
        view = Api.settings(actor)
        show(settings_form({"approval_mode" => view.approval_mode, "settlement_mode" => view.settlement_mode,
                            "batch_booking" => view.batch_booking ? "1" : "", "creditor_identifier" => view.creditor_identifier,
                            "ledger_id" => view.ledger_id.to_s}))
      end

      def post
        form = settings_form(FIELDS.to_h { |name| {name, field(name)} })
        input = Api::SettingsInput.new(approval_mode: field("approval_mode"), settlement_mode: field("settlement_mode"),
          batch_booking: checkbox("batch_booking"), creditor_identifier: field("creditor_identifier"),
          ledger_id: id_field("ledger_id"))
        result = Api.update_settings(actor, input)
        if result.success?
          flash["success"] = I18n.t("sepa_ui.flash.saved")
          return go(Ui.url("settings"))
        end
        form.add_errors(result.errors, fmt)
        show(form)
      end

      private def settings_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        approval = [
          Form::Field.new("approval_mode", I18n.t("sepa_ui.settings.approval_mode"), "select", value.call("approval_mode"),
            options: code_options(Api::APPROVAL_MODES, "sepa.approval_modes"), help: I18n.t("sepa_ui.settings.approval_help")),
          Form::Field.new("settlement_mode", I18n.t("sepa_ui.settings.settlement_mode"), "select", value.call("settlement_mode"),
            options: code_options(Api::SETTLEMENT_MODES, "sepa.settlement_modes"), help: I18n.t("sepa_ui.settings.settlement_help")),
        ]
        bank = [
          Form::Field.new("ledger_id", I18n.t("sepa_ui.settings.ledger"), "select", value.call("ledger_id"),
            options: ledger_options(blank: true)),
          Form::Field.new("batch_booking", I18n.t("sepa_ui.batches.batch_booking"), "checkbox", value.call("batch_booking"),
            help: I18n.t("sepa_ui.batches.batch_booking_help")),
          Form::Field.new("creditor_identifier", I18n.t("sepa_ui.settings.creditor_identifier"),
            value: value.call("creditor_identifier"), mono: true, maxlength: 35, help: I18n.t("sepa_ui.settings.creditor_identifier_help")),
        ]
        Form.new([Form::Group.new(I18n.t("sepa_ui.settings.validation"), approval), Form::Group.new(I18n.t("sepa_ui.settings.bank"), bank)])
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("sepa.menu.sepa_settings")
        form_page(title, settings_crumbs({title, nil}), form, Ui.url("settings"), I18n.t("ui.forms.save"), nil,
          intro: I18n.t("sepa_ui.settings.intro"))
      end
    end
  end
end
