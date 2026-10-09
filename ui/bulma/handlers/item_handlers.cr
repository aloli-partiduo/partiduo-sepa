# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  module Ui
    # Paiement saisi dans un lot en préparation (acompte, facture hors
    # comptabilité) : fiche, montant, communication, IBAN et BIC facultatifs
    # (ceux de la fiche ou du mandat sinon). Refusé : l'écran du lot est
    # rendu avec la saisie et le message (422).
    class ItemNewHandler < BatchHandler
      FIELDS = %w[card_code amount remittance iban bic]

      def get
        go(Ui.url("batch", id: id_param))
      end

      def post
        values = FIELDS.to_h { |name| {name, field(name)} }
        amount = fmt.parse_decimal(field("amount"))
        if amount.nil?
          return render_batch(Api.batch(actor, id_param), I18n.t("ui.forms.invalid_number"), 422, values)
        end
        input = Api::ItemInput.new(card_code: field("card_code"), amount: amount, remittance: field("remittance"),
          iban: field("iban"), bic: field("bic"))
        result = Api.add_item(actor, id_param, input)
        return after(result, "sepa_ui.flash.item_added", "#{Ui.url("batch", id: id_param)}#sepa-items") if result.success?
        render_batch(Api.batch(actor, id_param), messages(result), 422, values)
      end
    end

    # Correction d'un paiement (montant, communication) depuis sa ligne. En
    # HTMX, la ligne mise à jour (ou refusée, avec son message) remplace
    # l'ancienne ; sans JavaScript, le formulaire fonctionne par
    # redirection.
    class ItemHandler < Handler
      def get
        go(Ui.url("batch", id: Api.item(actor, id_param).batch_id))
      end

      def post
        current = Api.item(actor, id_param)
        amount = fmt.parse_decimal(field("amount"))
        result = if amount.nil?
                   nil
                 else
                   Api.update_item(actor, current.id, Api::ItemInput.new(card_code: current.card_code, amount: amount,
                     remittance: field("remittance"), iban: current.iban, bic: current.bic, name: current.name))
                 end
        error = if result.nil?
                  I18n.t("ui.forms.invalid_number")
                elsif result.failure?
                  messages(result)
                end
        if htmx?
          return fragment(Api.item(actor, current.id), error, error ? 422 : 200)
        end
        if error
          flash["danger"] = error
        else
          flash["success"] = I18n.t("sepa_ui.flash.item_saved")
        end
        go(back(Ui.url("batch", id: current.batch_id)))
      end

      def fragment(view : Api::ItemView, error : String?, status : Int32) : Marten::HTTP::Response
        batch = Api.batch(actor, view.batch_id)
        render("sepa/_item.html", {
          "item"       => Present.item(view, batch, fmt, can_prepare?),
          "debit"      => Ui.flag(batch.debit?),
          "form_error" => error,
          "next"       => field("next"),
        }, status: status)
      end
    end

    # Retire un paiement d'un lot en préparation.
    class ItemRemoveHandler < Handler
      def get
        go(Ui.url("batches"))
      end

      def post
        batch_id = Api.item(actor, id_param).batch_id
        after(Api.remove_item(actor, id_param), "sepa_ui.flash.item_removed", "#{Ui.url("batch", id: batch_id)}#sepa-items")
      end
    end
  end
end
