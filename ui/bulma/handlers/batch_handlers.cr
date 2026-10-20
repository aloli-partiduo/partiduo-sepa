# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  module Ui
    # `/ext/SEPA/batches` : les lots — genre, journal, date d'exécution,
    # paiements, total, statut. Liste triable, filtrable et exportable.
    class BatchesHandler < Handler
      def get
        columns = [
          Table::Column.new("date", I18n.t("sepa_ui.batches.requested_on"), "mono"),
          Table::Column.new("kind", I18n.t("sepa_ui.batches.kind")),
          Table::Column.new("label", I18n.t("sepa_ui.batches.label")),
          Table::Column.new("ledger", I18n.t("sepa_ui.batches.ledger"), "mono", secondary: true),
          Table::Column.new("count", I18n.t("sepa_ui.batches.count"), "number"),
          Table::Column.new("total", I18n.t("sepa_ui.batches.total"), "number"),
          Table::Column.new("status", I18n.t("sepa_ui.batches.status")),
        ]
        rows = Api.batches(actor, status: query("status").presence.try { |value| Api::STATUSES.includes?(value) ? value : nil }).map do |view|
          url = Ui.url("batch", id: view.id)
          Table::Row.new([
            Table::Cell.new(fmt.date(view.requested_on), url, sort: view.requested_on.to_s("%Y-%m-%d")),
            Table::Cell.new(I18n.t(view.kind_key), url),
            Table::Cell.new(view.label.presence || "—"),
            Table::Cell.new(view.ledger_code),
            Table::Cell.new(view.item_count.to_s, sort: BigDecimal.new(view.item_count)),
            Table::Cell.new(fmt.amount(view.total), sort: view.total),
            Table::Cell.new(I18n.t(view.status_key), tag: view.issued? && view.to_settle_count > 0 ? I18n.t("sepa_ui.batches.to_settle", count: view.to_settle_count) : nil),
          ])
        end
        table = Table.new(I18n.t("sepa.menu.sepa_batches"), columns, rows, Ui.url("batches"),
          empty_message: I18n.t("sepa_ui.batches.none"), id: "sepa-batches")
        actions = can_prepare? ? [link_action("sepa.menu.sepa_new", Ui.url("batch_new"), "primary", "plus")] : [] of Screen::Action
        list_page(I18n.t("sepa.menu.sepa_batches"), table, crumbs({I18n.t("sepa.menu.sepa_batches"), nil}),
          "sepa_ui.batches.csv_name", actions, intro: I18n.t("sepa_ui.batches.intro"))
      end
    end

    # Formulaire d'un lot (création, modification) : genre, journal,
    # date d'exécution ou d'échéance, libellé, comptabilisation groupée.
    abstract class BatchScreen < Handler
      FIELDS = %w[kind ledger_id requested_on label batch_booking]

      def submitted : Hash(String, String)
        FIELDS.to_h { |name| {name, field(name)} }
      end

      def batch_form(values : Hash(String, String), kind_locked : Bool = false) : Form
        value = ->(name : String) { values[name]? || "" }
        kinds = kind_locked ? code_options([value.call("kind")], "sepa.kinds") : code_options(Api::KINDS, "sepa.kinds")
        fields = [
          Form::Field.new("kind", I18n.t("sepa_ui.batches.kind"), "select", value.call("kind"), options: kinds, required: true),
          Form::Field.new("ledger_id", I18n.t("sepa_ui.batches.ledger"), "select", value.call("ledger_id"),
            options: ledger_options, required: true, help: I18n.t("sepa_ui.batches.ledger_help")),
          Form::Field.new("requested_on", I18n.t("sepa_ui.batches.requested_on"), "date", value.call("requested_on"),
            required: true, help: I18n.t("sepa_ui.batches.requested_on_help")),
          Form::Field.new("label", I18n.t("sepa_ui.batches.label"), value: value.call("label"), maxlength: 140, wide: true),
          Form::Field.new("batch_booking", I18n.t("sepa_ui.batches.batch_booking"), "checkbox", value.call("batch_booking"),
            help: I18n.t("sepa_ui.batches.batch_booking_help")),
        ]
        Form.new([Form::Group.new(nil, fields)])
      end

      def read_input(form : Form) : Api::BatchInput?
        date = fmt.parse_date(field("requested_on"))
        form.add_error("requested_on", I18n.t("ui.forms.invalid_date")) if date.nil?
        ledger_id = id_field("ledger_id")
        form.add_error("ledger_id", I18n.t("ui.forms.required")) if ledger_id.nil?
        return if form.invalid || date.nil? || ledger_id.nil?
        Api::BatchInput.new(kind: field("kind"), ledger_id: ledger_id, requested_on: date, label: field("label"),
          batch_booking: checkbox("batch_booking"))
      end
    end

    class BatchNewHandler < BatchScreen
      def get
        kind = Api::KINDS.includes?(query("kind")) ? query("kind") : "transfer"
        settings = Api.settings(actor)
        default_ledger = settings.ledger_id || ledgers.first?.try(&.id)
        show(batch_form({"kind" => kind, "ledger_id" => default_ledger.to_s, "requested_on" => Api.default_date(kind).to_s("%F"),
                         "batch_booking" => settings.batch_booking ? "1" : ""}))
      end

      def post
        form = batch_form(submitted)
        if input = read_input(form)
          result = Api.create_batch(actor, input)
          if result.success?
            flash["success"] = I18n.t("sepa_ui.flash.batch_created")
            return go(Ui.url("batch", id: result.value!.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("sepa.menu.sepa_new")
        form_page(title, crumbs({title, nil}), form, Ui.url("batch_new"), I18n.t("ui.forms.create"), Ui.url("batches"),
          intro: I18n.t("sepa_ui.batches.form_intro"))
      end
    end

    class BatchEditHandler < BatchScreen
      def get
        view = Api.batch(actor, id_param)
        values = {"kind" => view.kind, "ledger_id" => view.ledger_id.to_s, "requested_on" => view.requested_on.to_s("%F"),
                  "label" => view.label, "batch_booking" => view.batch_booking ? "1" : ""}
        show(view, batch_form(values, !view.items.empty?))
      end

      def post
        view = Api.batch(actor, id_param)
        form = batch_form(submitted, !view.items.empty?)
        if input = read_input(form)
          result = Api.update_batch(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("sepa_ui.flash.saved")
            return go(Ui.url("batch", id: view.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::BatchView, form : Form) : Marten::HTTP::Response
        title = I18n.t("sepa_ui.batch.title", id: view.id)
        form_page(title, crumbs({I18n.t("sepa.menu.sepa_batches"), Ui.url("batches")}, {title, Ui.url("batch", id: view.id)},
          {I18n.t("sepa_ui.batch.edit"), nil}), form, Ui.url("batch_edit", id: view.id), I18n.t("ui.forms.save"),
          Ui.url("batch", id: view.id))
      end
    end

    # `/ext/SEPA/batches/<id>` : un lot — faits, contrôle, paiements
    # (corrigés en HTMX tant qu'il est en préparation), écritures ouvertes
    # à ajouter, saisie d'un paiement, puis préparation, approbation,
    # fichier, émission et règlements selon son statut et les droits.
    class BatchHandler < Handler
      def get
        render_batch(Api.batch(actor, id_param))
      end

      def render_batch(view : Api::BatchView, error : String? = nil, status : Int32 = 200,
                       manual = {} of String => String) : Marten::HTTP::Response
        problems = problems_of(view)
        composing = view.draft? && can_prepare?
        candidates = composing ? candidate_rows(view) : [] of Row
        settings = Api.settings(actor)
        approval = view.status == "prepared" ? Api.approval(actor, view.id) : nil
        page("sepa/batch.html", {
          "title"        => I18n.t("sepa_ui.batch.title", id: view.id),
          "crumbs"       => crumbs({I18n.t("sepa.menu.sepa_batches"), Ui.url("batches")}, {I18n.t("sepa_ui.batch.title", id: view.id), nil}),
          "actions"      => header_actions(view, approval),
          "batch"        => Present.batch(view, fmt),
          "items"        => view.items.map { |item| Present.item(item, view, fmt, can_prepare?) },
          "debit"        => Ui.flag(view.debit?),
          "draft"        => Ui.flag(view.draft?),
          "batch_issued" => Ui.flag(view.issued?),
          "can_prepare"  => Ui.flag(composing),
          "problems"     => problems.empty? ? nil : problems.map { |text| Ui.row({"text" => text}) },
          "ready"        => Ui.flag(view.draft? && problems.empty?),
          "candidates"   => candidates.empty? ? nil : candidates,
          "add_url"      => Ui.url("batch_add", id: view.id),
          "item_new_url" => Ui.url("item_new", id: view.id),
          "cards"        => composing ? card_list(view.debit? ? "customer" : "supplier") : [] of Row,
          "manual"       => Ui.row(manual),
          "can_issue"    => Ui.flag(can_approve? && view.status == "approved"),
          "issue_url"    => Ui.url("batch_issue", id: view.id),
          "today"        => Partiduo::Api::Core.today.to_s("%F"),
          "settle_mode"  => I18n.t("sepa.settlement_modes.#{settings.settlement_mode}"),
          "approval"     => view.status == "prepared" ? Present.approval(approval, settings, actor, fmt) : nil,
          "error"        => error,
          "next"         => request.full_path,
        }, status: status)
      end

      # Ce qui empêcherait de préparer le lot (lot en préparation seulement).
      private def problems_of(view : Api::BatchView) : Array(String)
        return [] of String unless view.draft?
        Api.check_batch(actor, view.id).errors.map { |item| fmt.message(item) }
      end

      private def candidate_rows(view : Api::BatchView) : Array(Row)
        Api.candidates(actor, view.id).map do |item|
          Ui.row({
            "line_id" => item.line_id.to_s, "card" => "#{item.card_code} · #{item.card_name}",
            "date" => fmt.date(item.date), "due" => item.due_date.try { |date| fmt.date(date) },
            "receipt" => item.receipt, "label" => item.label, "amount" => fmt.amount(item.amount),
            "iban" => item.iban.empty? ? nil : Api.mask_iban(item.iban),
            "problem" => item.problem.try { |key| I18n.t("sepa_ui.candidates.problems.#{key.tr(".", "_")}") },
          })
        end
      rescue Partiduo::Api::AccessDenied
        [] of Row
      end

      private def header_actions(view : Api::BatchView, approval : Partiduo::Api::Approvals::ApprovalView?) : Array(Screen::Action)
        case view.status
        when "draft"    then draft_actions(view)
        when "prepared" then prepared_actions(view, approval)
        when "approved" then approved_actions(view)
        else                 issued_actions(view)
        end
      end

      private def draft_actions(view : Api::BatchView) : Array(Screen::Action)
        return [] of Screen::Action unless can_prepare?
        [post_action("sepa_ui.batch.prepare", Ui.url("batch_prepare", id: view.id), nil, "primary", "check"),
         link_action("sepa_ui.batch.edit", Ui.url("batch_edit", id: view.id), "", "pencil"),
         post_action("sepa_ui.batch.delete", Ui.url("batch_delete", id: view.id), "sepa_ui.batch.delete_confirm", "danger", "trash-2")]
      end

      # L'approbation se décide dans l'écran commun « Approbations »
      # (D-SEPA-017) : « Approuver » y mène, pour qui peut décider ; en
      # validation à deux, l'écran commun le refuse au préparateur.
      private def prepared_actions(view : Api::BatchView, approval : Partiduo::Api::Approvals::ApprovalView?) : Array(Screen::Action)
        actions = [] of Screen::Action
        if approval && approval.pending? && can_approve?
          actions << link_action("sepa_ui.batch.approve", Marten.routes.reverse("core:approval", id: approval.id), "primary", "shield-check")
        end
        if can_prepare?
          actions << post_action("sepa_ui.batch.reopen", Ui.url("batch_reopen", id: view.id), nil, "", "undo-2")
          actions << post_action("sepa_ui.batch.delete", Ui.url("batch_delete", id: view.id), "sepa_ui.batch.delete_confirm", "danger", "trash-2")
        end
        actions
      end

      private def approved_actions(view : Api::BatchView) : Array(Screen::Action)
        actions = [link_action("sepa_ui.batch.download", Ui.url("batch_file", id: view.id), "primary", "download")]
        actions << post_action("sepa_ui.batch.reopen", Ui.url("batch_reopen", id: view.id), "sepa_ui.batch.reopen_confirm", "", "undo-2") if can_prepare?
        actions
      end

      private def issued_actions(view : Api::BatchView) : Array(Screen::Action)
        actions = [link_action("sepa_ui.batch.download", Ui.url("batch_file", id: view.id), "", "download")]
        if can_approve? && view.to_settle_count > 0
          actions << post_action("sepa_ui.batch.settle", Ui.url("batch_settle", id: view.id), nil, "primary", "send")
        end
        actions
      end
    end

    # Ajoute les écritures ouvertes cochées.
    class BatchAddHandler < Handler
      def get
        go(Ui.url("batch", id: id_param))
      end

      def post
        result = Api.add_open_items(actor, id_param, checked_ids)
        if result.success?
          flash["success"] = I18n.t("sepa_ui.flash.added", count: result.value!)
        else
          flash["danger"] = messages(result)
        end
        go(Ui.url("batch", id: id_param))
      end
    end

    # Commandes de cycle de vie d'un lot (préparer, approuver, rouvrir,
    # supprimer), sur la même forme : commande, message, retour au lot.
    abstract class BatchCommandHandler < BatchHandler
      def get
        go(Ui.url("batch", id: id_param))
      end

      abstract def command : Partiduo::Api::Result(Api::BatchView)
      abstract def success_key : String

      def post
        result = command
        return after(result, success_key, Ui.url("batch", id: id_param)) if result.success?
        render_batch(Api.batch(actor, id_param), messages(result), 422)
      rescue ex : Partiduo::Api::Forbidden
        flash["danger"] = I18n.t(ex.key)
        go(Ui.url("batch", id: id_param))
      end
    end

    class BatchPrepareHandler < BatchCommandHandler
      def command : Partiduo::Api::Result(Api::BatchView)
        Api.prepare(actor, id_param)
      end

      def success_key : String
        "sepa_ui.flash.prepared"
      end
    end

    # `/ext/SEPA/batches/<id>/approve` : l'approbation se décide dans
    # l'écran commun « Approbations » (D-SEPA-017) ; renvoie à la demande en
    # attente du lot, sinon au lot.
    class BatchApproveHandler < Handler
      def get
        approval = Api.approval(actor, id_param)
        return go(Marten.routes.reverse("core:approval", id: approval.id)) if approval && approval.pending?
        flash["warning"] = I18n.t("sepa_ui.batch.no_pending_approval")
        go(Ui.url("batch", id: id_param))
      end

      def post
        get
      end
    end

    class BatchReopenHandler < BatchCommandHandler
      def command : Partiduo::Api::Result(Api::BatchView)
        Api.reopen(actor, id_param)
      end

      def success_key : String
        "sepa_ui.flash.reopened"
      end
    end

    class BatchDeleteHandler < Handler
      def get
        go(Ui.url("batch", id: id_param))
      end

      def post
        result = Api.delete_batch(actor, id_param)
        return after(result, "sepa_ui.flash.batch_deleted", Ui.url("batches")) if result.success?
        after(result, "", Ui.url("batch", id: id_param))
      end
    end

    # Confirme l'émission (date de dépôt du fichier à la banque) ; selon
    # le réglage, les règlements sont passés aussitôt.
    class BatchIssueHandler < Handler
      def get
        go(Ui.url("batch", id: id_param))
      end

      def post
        day = fmt.parse_date(field("issued_on"))
        if day.nil?
          flash["danger"] = I18n.t("ui.forms.invalid_date")
          return go(Ui.url("batch", id: id_param))
        end
        result = Api.confirm_issue(actor, id_param, day)
        return report(result, "sepa_ui.flash.issued") if result.success?
        after(result, "", Ui.url("batch", id: id_param))
      end

      def report(result, key : String) : Marten::HTTP::Response
        view = result.value!
        flash["success"] = I18n.t(key, count: view.posted.size)
        notes = [] of String
        notes << I18n.t("sepa_ui.flash.elsewhere", count: view.elsewhere.size) unless view.elsewhere.empty?
        notes << I18n.t("sepa_ui.flash.settle_failed", count: view.failed.size) unless view.failed.empty?
        flash["warning"] = notes.join(" ") unless notes.empty?
        go(Ui.url("batch", id: id_param))
      end
    end

    class BatchSettleHandler < BatchIssueHandler
      def post
        result = Api.post_settlements(actor, id_param)
        return report(result, "sepa_ui.flash.settled") if result.success?
        after(result, "", Ui.url("batch", id: id_param))
      end
    end

    # Fichier ISO 20022 du lot, relu dans les pièces jointes du socle.
    class BatchFileHandler < Handler
      def get
        found = Api.file(actor, id_param)
        return PartiduoUi::ErrorPage.render(request, 404) if found.nil?
        filename, content_type, bytes = found
        response = Marten::HTTP::Response.new(String.new(bytes), content_type: content_type)
        response.headers["Content-Disposition"] = %(attachment; filename="#{filename.gsub(/["\\\r\n]/, "_")}")
        response
      rescue Partiduo::Api::AccessDenied
        PartiduoUi::ErrorPage.render(request, 403)
      end
    end
  end
end
