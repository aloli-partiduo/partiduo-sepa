# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"

module Sepa
  # Double validation d'un lot par le service commun du socle
  # (`Partiduo::Api::Approvals`, A-SEPA-3, D-SEPA-017) : le lot préparé est
  # soumis avec l'empreinte de son contenu ; à l'approbation (écran commun
  # « Approbations » ou `Sepa::Api.approve`), le gestionnaire déclaré pour
  # `SEPA`/`batch` relit le lot, le recontrôle, recalcule l'empreinte, produit
  # le fichier, consomme l'approbation pour cette empreinte (une seule
  # exécution ; un lot modifié après la soumission n'est pas exécuté), puis
  # conserve le fichier. Tout se passe dans la transaction de l'approbation :
  # un refus la laisse en attente. Interne.
  module Approval
    alias Approvals = Partiduo::Api::Approvals
    alias FieldError = Partiduo::Api::FieldError
    alias Result = Partiduo::Api::Result

    PREFIX = "batch:"

    def self.subject(batch_id : Int64) : String
      "#{PREFIX}#{batch_id}"
    end

    def self.batch_id(subject : String) : Int64?
      subject.starts_with?(PREFIX) ? subject.lchop(PREFIX).to_i64? : nil
    end

    # Empreinte SHA-256 de ce qu'approuve la personne : le lot (genre,
    # journal, date, libellé, comptabilisation), le compte donneur d'ordre
    # ou créancier, l'ICS d'un prélèvement et chaque paiement (tiers,
    # coordonnées, montant au centime, communication, référence, écriture,
    # mandat et séquence figés à la préparation).
    def self.digest(batch : Batch, items : Array(Item), account : Preparation::Account?, ics : String) : String
      text = JSON.build do |json|
        json.object do
          json.field "batch", [batch.id.to_s, batch.kind.to_s, batch.ledger_id.to_s, day(batch.requested_on),
                               (batch.batch_booking == true).to_s, batch.label.to_s]
          json.field "account", account ? [account.name, account.iban, account.bic] : [] of String
          json.field "ics", batch.kind == "debit" ? ics : ""
          json.field "items" do
            json.array do
              items.sort_by(&.position!).each do |row|
                json.array do
                  [row.id.to_s, row.position.to_s, row.card_code.to_s, row.name.to_s, row.iban.to_s, row.bic.to_s,
                   cents(row.amount!), row.remittance.to_s, row.end_to_end_id.to_s, row.entry_line_id.to_s,
                   row.mandate_id.to_s, row.sequence_type.to_s, row.mandate_rum.to_s, day(row.mandate_signed_on),
                   row.original_iban.to_s].each { |value| json.string value }
                end
              end
            end
          end
        end
      end
      Digest::SHA256.hexdigest(text)
    end

    # Empreinte du lot tel qu'il est enregistré.
    def self.current_digest(actor : Partiduo::Api::Actor, batch : Batch) : String
      items = Item.filter(batch_id: batch.id).order(:position).to_a
      account = Preparation.account(actor, batch, [] of FieldError)
      digest(batch, items, account, Settings.creditor_identifier)
    end

    # Soumet le lot préparé au service d'approbation, au nom de la personne
    # qui l'a préparé.
    def self.submit(actor : Partiduo::Api::Actor, batch : Batch) : Result(Approvals::ApprovalView)
      items = Item.filter(batch_id: batch.id).order(:position).to_a
      total = items.sum(BigDecimal.new(0), &.amount!)
      kind = I18n.t("sepa.kinds.#{batch.kind}")
      date = day(batch.requested_on)
      label = batch.label.to_s.strip
      summary = I18n.t("sepa.approval.summary", id: batch.id, kind: kind, date: date)
      summary = "#{summary} · #{label}" unless label.empty?
      ledger = Records.visible_ledgers(actor).find(&.id.==(batch.ledger_id!.to_i64))
      details = {
        "sepa.approval.details.kind"         => kind,
        "sepa.approval.details.ledger"       => ledger.try(&.code) || batch.ledger_id.to_s,
        "sepa.approval.details.requested_on" => date,
        "sepa.approval.details.count"        => items.size.to_s,
        "sepa.approval.details.schema"       => batch.kind == "debit" ? Api::DEBIT_SCHEMA : Api::TRANSFER_SCHEMA,
      }
      input = Approvals::SubmitInput.new(module_code: Sepa::CODE, kind: Api::APPROVAL_KIND, subject: subject(batch.id!.to_i64),
        summary: summary, digest: current_digest(actor, batch), permission: Api::APPROVE, amount: total,
        currency_code: "EUR", details: details)
      Approvals.submit(actor, input)
    end

    # Demande en attente pour le lot, ou `nil`.
    def self.pending(batch_id : Int64) : Approvals::ApprovalView?
      latest(batch_id).try { |view| view.pending? ? view : nil }
    end

    # Dernière demande du lot, quel que soit son état.
    def self.latest(batch_id : Int64) : Approvals::ApprovalView?
      Approvals.latest(Partiduo::Api::Actor.system, Sepa::CODE, Api::APPROVAL_KIND, subject(batch_id))
    end

    # Retire la demande en attente du lot (rouvert ou supprimé) : l'objet a
    # changé, l'extension retire elle-même la demande (acteur système).
    def self.withdraw(batch_id : Int64, reason : String) : Nil
      pending(batch_id).try { |view| Approvals.cancel(Partiduo::Api::Actor.system, view.id, reason) }
    end

    # Gestionnaire de l'approbation (`Approvals.register_handler`) : exécute
    # le lot approuvé par `actor`.
    def self.execute(actor : Partiduo::Api::Actor, approval : Approvals::ApprovalView) : Result(Nil)
      id = batch_id(approval.subject) || return refuse("approval.not_prepared")
      batch = Batch.filter(id: id).lock.first || return refuse("approval.not_prepared")
      return refuse("approval.not_prepared") unless batch.status == "prepared"
      Records.batch!(actor, id)
      return refuse("approval.attachment_permission") unless actor.can?(Api::ATTACHMENT_PERMISSION)
      items = Item.filter(batch_id: id).order(:position).to_a
      errors = Preparation.errors(actor, batch, items)
      return Result(Nil).failure(errors) unless errors.empty?
      account = Preparation.account(actor, batch, errors) || raise "compte du lot introuvable"
      ics = Settings.creditor_identifier
      digest = digest(batch, items, account, ics)
      return refuse("approval.changed") unless digest == approval.digest
      produce(actor, approval, batch, items, account, ics, digest)
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      refuse("approval.forbidden")
    end

    # Fichier produit et contrôlé, approbation consommée pour l'empreinte,
    # fichier conservé, lot approuvé.
    private def self.produce(actor : Partiduo::Api::Actor, approval : Approvals::ApprovalView, batch : Batch,
                             items : Array(Item), account : Preparation::Account, ics : String, digest : String) : Result(Nil)
      id = batch.id!.to_i64
      now = Partiduo::Config.now
      message_id = XmlBuilder.message_id(id, now)
      content = XmlBuilder.build(XmlBuilder::Input.new(batch, items, account, ics, message_id, now, Producer.addresses(items)))
      problems = Producer.problems(content, batch.kind.to_s)
      unless problems.empty?
        return refuse("file.invalid", {"detail" => problems.first(5).join(" ; ")})
      end
      consumed = Approvals.consume(actor, approval.id, Approvals::ConsumeInput.new(Sepa::CODE, Api::APPROVAL_KIND,
        approval.subject, digest))
      return Result(Nil).failure(consumed.errors) if consumed.failure?
      view = Records.batch_view(actor, batch)
      stored = Partiduo::Api::Core.store_attachment(actor, Partiduo::Api::Core::AttachmentInput.new(
        view.filename, "application/xml", IO::Memory.new(content)))
      return Result(Nil).failure(stored.errors) if stored.failure?
      batch.status = "approved"
      batch.approval_mode = approval.decision_mode.presence || approval.mode
      batch.approved_by_id = actor.user_id
      batch.approved_at = now
      batch.message_id = message_id
      batch.attachment_id = stored.value!.id
      batch.file_sha256 = stored.value!.sha256
      batch.save!
      Result(Nil).success(nil)
    end

    private def self.refuse(key : String, params = {} of String => String) : Result(Nil)
      Result(Nil).failure(Records.error(FieldError::BASE, key, params))
    end

    private def self.cents(amount : BigDecimal) : String
      (amount * 100).round.to_i64.to_s
    end

    private def self.day(date : Time?) : String
      date.try(&.to_s("%Y-%m-%d")) || ""
    end
  end
end

# Exécution d'un lot approuvé, depuis l'écran commun d'approbation ou
# `Sepa::Api.approve` (D-SEPA-017).
Partiduo::Api::Approvals.register_handler(Sepa::CODE, Sepa::Api::APPROVAL_KIND) do |actor, approval|
  Sepa::Approval.execute(actor, approval)
end
