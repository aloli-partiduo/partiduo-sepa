# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  module Ui
    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom (un
    # grand `Hash` n'est pas lu par les gabarits Marten, B-EINV-001 du cœur).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)
      getter children : Hash(String, Array(Row))

      def initialize(values : Hash(String, String) | Hash(String, String?), @children = {} of String => Array(Row))
        @values = values.transform_values(&.as(String?))
      end

      def resolve_template_attribute(key : String)
        if list = children[key]?
          list.empty? ? nil : list
        else
          values[key]?
        end
      end
    end

    def self.row(values : Hash(String, String) | Hash(String, String?), children = {} of String => Array(Row)) : Row
      Row.new(values, children)
    end

    def self.url(name : String, **params) : String
      Marten.routes.reverse("sepa:#{name}", **params)
    end

    def self.flag(value : Bool) : String?
      value ? "1" : nil
    end

    # Classe Bulma du statut d'un lot.
    def self.status_class(status : String) : String
      case status
      when "issued"   then "is-success"
      when "approved" then "is-link"
      when "prepared" then "is-warning"
      else                 "is-info"
      end
    end

    # Classe Bulma de l'état du règlement d'un paiement.
    def self.settlement_class(settlement : String) : String
      case settlement
      when "posted"    then "is-success"
      when "elsewhere" then "is-light"
      else                  "is-warning"
      end
    end

    # Présentation des vues du contrat (interne à l'interface).
    module Present
      alias Api = Sepa::Api

      def self.item(view : Api::ItemView, batch : Api::BatchView, fmt : PartiduoUi::Format, can_prepare : Bool) : Row
        Ui.row({
          "id"               => view.id.to_s,
          "position"         => view.position.to_s,
          "card_code"        => view.card_code,
          "name"             => view.name,
          "iban"             => Api.format_iban(view.iban),
          "bic"              => view.bic.presence,
          "amount"           => fmt.amount(view.amount),
          "amount_input"     => fmt.input_number(view.amount),
          "remittance"       => view.remittance,
          "reference_kind"   => view.reference_kind == "text" ? nil : I18n.t("sepa_ui.items.reference_#{view.reference_kind}"),
          "end_to_end_id"    => view.end_to_end_id,
          "receipt"          => view.receipt.presence,
          "due_on"           => view.due_on.try { |date| fmt.date(date) },
          "entry_url"        => view.entry_id.try { |id| Marten.routes.reverse("accounting:entry", id: id) },
          "sequence"         => view.sequence_type.presence.try { |code| I18n.t("sepa.sequences.#{code}") },
          "mandate_rum"      => view.mandate_rum.presence,
          "amended"          => Ui.flag(view.amended),
          "iban_differs"     => Ui.flag(view.iban_differs?),
          "card_iban"        => view.card_iban.try { |iban| Api.format_iban(iban) },
          "settlement"       => batch.issued? ? I18n.t(view.settlement_key) : nil,
          "settlement_class" => Ui.settlement_class(view.settlement),
          "settlement_url"   => view.settlement_entry_id.try { |id| Marten.routes.reverse("accounting:entry", id: id) },
          "error"            => view.error.try { |error| fmt.message(error) },
          "update_url"       => Ui.url("item", id: view.id),
          "remove_url"       => Ui.url("item_remove", id: view.id),
          "editable"         => Ui.flag(can_prepare && batch.draft?),
        })
      end

      def self.batch(view : Api::BatchView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "id"            => view.id.to_s,
          "url"           => Ui.url("batch", id: view.id),
          "kind"          => I18n.t(view.kind_key),
          "status"        => I18n.t(view.status_key),
          "status_class"  => Ui.status_class(view.status),
          "label"         => view.label.presence,
          "ledger"        => view.ledger_code,
          "requested_on"  => fmt.date(view.requested_on),
          "count"         => view.item_count.to_s,
          "total"         => fmt.amount(view.total),
          "schema"        => view.schema,
          "message_id"    => view.message_id.presence,
          "approval_mode" => view.approval_mode.presence.try { |mode| I18n.t("sepa.approval_modes.#{mode}") },
          "issued_on"     => view.issued_on.try { |date| fmt.date(date) },
          "file_sha256"   => view.file_sha256.presence,
          "booking"       => I18n.t(view.batch_booking ? "sepa_ui.batch.booking_grouped" : "sepa_ui.batch.booking_single"),
        })
      end
    end
  end
end
