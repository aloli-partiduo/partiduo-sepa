# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Contrat public de l'extension des paiements SEPA, sur le modèle de
  # `Partiduo::Api` (DECISIONS C2 du cœur) : acteur en premier argument,
  # contrôle d'accès en première ligne (extension active et permission),
  # objets de vue immuables, toute écriture par une commande qui rend un
  # `Result` avec ses erreurs par champ, dans une transaction. L'interface
  # de l'extension (`ui/bulma/`) ne voit que ce module et `Partiduo::Api`.
  #
  # Cycle d'un lot (D-SEPA-005) : `draft` (composer) → `prepare` (contrôlé
  # et figé) → `approve` (fichier produit, contrôlé, conservé) →
  # `confirm_issue` (émission confirmée, règlements passés ou proposés).
  # `reopen` ramène un lot préparé ou approuvé en préparation. Aucun envoi
  # à la banque : l'utilisateur dépose le fichier lui-même.
  #
  # Référence : `doc/api/sepa.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError
    alias Transaction = Partiduo::Api::Transaction

    MODULE_CODE = Sepa::CODE
    READ        = "sepa.read"
    PREPARE     = "sepa.prepare"
    APPROVE     = "sepa.approve"
    ADMIN       = "sepa.admin"

    # Permission du socle exigée en plus pour approuver : le fichier est
    # conservé en pièce jointe (D-SEPA-004).
    ATTACHMENT_PERMISSION = "core.attachment.write"

    # --- Contrôles purs ------------------------------------------------------------

    def self.iban_valid?(value : String) : Bool
      Codes.valid_iban?(value)
    end

    def self.bic_valid?(value : String) : Bool
      Codes.valid_bic?(value)
    end

    def self.ics_valid?(value : String) : Bool
      Codes.valid_ics?(value)
    end

    def self.format_iban(value : String) : String
      Codes.format_iban(value)
    end

    def self.mask_iban(value : String) : String
      Codes.mask(value)
    end

    # Texte ramené au jeu de caractères SEPA (accents translittérés).
    def self.transliterate(text : String, max : Int32? = nil) : String
      Charset.transliterate(text, max)
    end

    # Premier jour ouvré TARGET à partir de `date`.
    def self.next_business_day(date : Time) : Time
      Calendar.next_business_day(date)
    end

    # Date d'exécution proposée pour un nouveau lot : le jour ouvré suivant.
    def self.default_date(kind : String) : Time
      Calendar.next_business_day(Partiduo::Config.today + (kind == "debit" ? 2.days : 1.day))
    end

    # --- Réglages ------------------------------------------------------------------

    def self.settings(actor : Actor) : SettingsView
      authorize!(actor, READ)
      Settings.view
    end

    def self.update_settings(actor : Actor, input : SettingsInput) : Result(SettingsView)
      authorize!(actor, ADMIN)
      errors = [] of FieldError
      errors << Records.error("approval_mode", "choice.invalid", {"value" => input.approval_mode}) unless APPROVAL_MODES.includes?(input.approval_mode)
      errors << Records.error("settlement_mode", "choice.invalid", {"value" => input.settlement_mode}) unless SETTLEMENT_MODES.includes?(input.settlement_mode)
      ics = Codes.compact(input.creditor_identifier)
      errors << Records.error("creditor_identifier", "settings.ics_invalid") unless ics.empty? || Codes.valid_ics?(ics)
      input.ledger_id.try { |id| Records.financial_ledger(actor, id, "ledger_id", errors) }
      return Result(SettingsView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Settings.row || Setting.new
        Settings.apply(row, input).save!
        Result(SettingsView).success(Settings.view)
      end
    end

    # --- Mandats -------------------------------------------------------------------

    # Mandats, par fiche puis date de signature ; `card_code` : ceux d'un
    # client ; `status` : `nil` = tous.
    def self.mandates(actor : Actor, card_code : String? = nil, status : String? = nil) : Array(MandateView)
      authorize!(actor, READ)
      rows = Mandate.all
      card_code.try(&.strip.presence).try { |code| rows = rows.filter(card_code__iexact: code) }
      status.try { |value| rows = rows.filter(status: value) }
      Records.mandate_views(actor, rows.order(:card_code, "-signed_on", "-id").to_a)
    end

    def self.mandate(actor : Actor, id : Int64) : MandateView
      authorize!(actor, READ)
      Records.mandate_view(actor, Records.mandate!(id))
    end

    # Enregistre un mandat signé (D-SEPA-007). Erreurs :
    # `sepa.errors.mandate.*`, `.iban.invalid`, `.bic.invalid`.
    def self.create_mandate(actor : Actor, input : MandateInput) : Result(MandateView)
      authorize!(actor, ADMIN)
      errors = Mandates.errors(actor, input, nil)
      return Result(MandateView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Mandates.apply(actor, Mandate.new(status: "active", collection_count: 0, created_by_id: actor.user_id), input)
        row.save!
        Result(MandateView).success(Records.mandate_view(actor, row))
      end
    end

    # Modifie un mandat actif. Après un premier prélèvement, la RUM et la
    # nature ne changent plus ; un IBAN changé est signalé à la banque au
    # prélèvement suivant (amendement).
    def self.update_mandate(actor : Actor, id : Int64, input : MandateInput) : Result(MandateView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.mandate!(id, lock: true)
        next Result(MandateView).failure(Records.error(FieldError::BASE, "mandate.not_active")) unless row.status == "active"
        errors = Mandates.errors(actor, input, row)
        if row.collection_count!.positive? && Records.card(actor, input.card_code).try(&.code) != row.card_code
          errors << Records.error("card_code", "mandate.card.frozen")
        end
        next Result(MandateView).failure(errors) unless errors.empty?
        Mandates.apply(actor, row, input).save!
        Result(MandateView).success(Records.mandate_view(actor, row))
      end
    end

    # Révoque un mandat (à la demande du débiteur) : plus aucun
    # prélèvement ; un lot en préparation qui l'emploie sera refusé.
    def self.revoke_mandate(actor : Actor, id : Int64, on : Time? = nil) : Result(MandateView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.mandate!(id, lock: true)
        next Result(MandateView).failure(Records.error(FieldError::BASE, "mandate.not_active")) unless row.status == "active"
        row.status = "revoked"
        row.revoked_on = on || Partiduo::Config.today
        row.save!
        Result(MandateView).success(Records.mandate_view(actor, row))
      end
    end

    # Supprime un mandat qu'aucun paiement n'a employé (saisie erronée).
    def self.delete_mandate(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.mandate!(id, lock: true)
        next Result(Nil).failure(Records.error(FieldError::BASE, "mandate.in_use")) if Item.filter(mandate_id: id).exists?
        row.delete
        Result(Nil).success(nil)
      end
    end

    # --- Lots ----------------------------------------------------------------------

    # Lots des journaux visibles, les plus récents d'abord ; `status` :
    # `nil` = tous.
    def self.batches(actor : Actor, status : String? = nil, kind : String? = nil, limit : Int32 = 500) : Array(BatchView)
      authorize!(actor, READ)
      ids = Records.visible_ledger_ids(actor)
      return [] of BatchView if ids.empty?
      rows = Batch.filter(ledger_id__in: ids)
      status.try { |value| rows = rows.filter(status: value) }
      kind.try { |value| rows = rows.filter(kind: value) }
      Records.batch_views(actor, rows.order("-requested_on", "-id")[0...limit.clamp(1, 1000)].to_a)
    end

    def self.batch(actor : Actor, id : Int64) : BatchView
      authorize!(actor, READ)
      Records.batch_view(actor, Records.batch!(actor, id))
    end

    # Ouvre un lot en préparation. Erreurs : `sepa.errors.ledger.*`,
    # `.date.*`, `.batch.*`, `.choice.invalid`.
    def self.create_batch(actor : Actor, input : BatchInput) : Result(BatchView)
      authorize!(actor, PREPARE)
      errors = Items.batch_errors(actor, input)
      return Result(BatchView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Items.apply_batch(Batch.new(status: "draft", created_by_id: actor.user_id), input, Settings.view)
        row.save!
        Result(BatchView).success(Records.batch_view(actor, row))
      end
    end

    # Modifie un lot en préparation (le genre ne change pas s'il a des
    # paiements).
    def self.update_batch(actor : Actor, id : Int64, input : BatchInput) : Result(BatchView)
      authorize!(actor, PREPARE)
      Transaction.run do
        row = Records.batch!(actor, id, lock: true)
        next draft_only(BatchView) unless row.status == "draft"
        errors = Items.batch_errors(actor, input)
        if input.kind != row.kind && Item.filter(batch_id: id).exists?
          errors << Records.error("kind", "batch.kind_frozen")
        end
        next Result(BatchView).failure(errors) unless errors.empty?
        Items.apply_batch(row, input, Settings.view).save!
        Result(BatchView).success(Records.batch_view(actor, row))
      end
    end

    # Supprime un lot en préparation ou préparé (un lot approuvé se rouvre
    # d'abord ; un lot émis est conservé).
    def self.delete_batch(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, PREPARE)
      Transaction.run do
        row = Records.batch!(actor, id, lock: true)
        unless row.status.in?("draft", "prepared")
          next Result(Nil).failure(Records.error(FieldError::BASE, "batch.not_deletable"))
        end
        row.delete
        Result(Nil).success(nil)
      end
    end

    # Écritures ouvertes que le lot peut régler (D-SEPA-009) : factures
    # fournisseurs non lettrées (virements) ou factures clients non lettrées
    # des clients sous mandat actif (prélèvements). Exige aussi
    # `accounting.entry.read` et `cards.card.read`.
    def self.candidates(actor : Actor, batch_id : Int64) : Array(CandidateView)
      authorize!(actor, READ)
      row = Records.batch!(actor, batch_id)
      Candidates.list(actor, row.kind.to_s)
    end

    # Ajoute au lot les écritures ouvertes choisies, au montant ouvert
    # entier. Rend le nombre de paiements ajoutés ; une écriture qui n'est
    # plus ouverte, déjà engagée ou sans IBAN valable est refusée.
    def self.add_open_items(actor : Actor, batch_id : Int64, line_ids : Array(Int64)) : Result(Int32)
      authorize!(actor, PREPARE)
      return Result(Int32).failure(Records.error("line_ids", "item.none_selected")) if line_ids.empty?
      Transaction.run do
        batch = Records.batch!(actor, batch_id, lock: true)
        next draft_only(Int32) unless batch.status == "draft"
        found = Candidates.list(actor, batch.kind.to_s).to_h { |item| {item.line_id, item} }
        errors = [] of FieldError
        line_ids.uniq.each do |line_id|
          candidate = found[line_id]?
          if candidate.nil?
            errors << Records.error("line_ids", "item.line_unavailable", {"id" => line_id.to_s})
          elsif problem = candidate.problem
            errors << Records.error("line_ids", "item.candidate_#{problem.tr(".", "_")}",
              {"code" => candidate.card_code, "receipt" => candidate.receipt.to_s})
          end
        end
        next Result(Int32).failure(errors) unless errors.empty?
        position = Item.filter(batch_id: batch_id).count.to_i32
        line_ids.uniq.each_with_index(1) do |line_id, index|
          row = Items.from_candidate(actor, batch, found[line_id])
          row.position = position + index
          row.save!
        end
        Items.renumber!(batch)
        Result(Int32).success(line_ids.uniq.size)
      end
    end

    # Ajoute un paiement saisi (acompte, facture hors comptabilité) : fiche,
    # montant, communication ; coordonnées bancaires de la fiche (virement)
    # ou de son mandat actif (prélèvement), sauf saisie.
    def self.add_item(actor : Actor, batch_id : Int64, input : ItemInput) : Result(ItemView)
      authorize!(actor, PREPARE)
      Transaction.run do
        batch = Records.batch!(actor, batch_id, lock: true)
        next draft_only(ItemView) unless batch.status == "draft"
        errors = Items.item_errors(actor, batch, input)
        next Result(ItemView).failure(errors) unless errors.empty?
        row = Items.apply_item(actor, batch, Item.new(batch_id: batch_id, settlement: "none"), input)
        row.position = Item.filter(batch_id: batch_id).count.to_i32 + 1
        row.save!
        Items.renumber!(batch)
        Result(ItemView).success(Records.item_view(actor, Item.filter(id: row.id).first!))
      end
    end

    # Corrige un paiement d'un lot en préparation : montant (au plus le
    # montant ouvert de l'écriture réglée), communication, coordonnées.
    def self.update_item(actor : Actor, id : Int64, input : ItemInput) : Result(ItemView)
      authorize!(actor, PREPARE)
      Transaction.run do
        row = Records.item!(actor, id)
        batch = Records.batch!(actor, row.batch_id!.to_i64, lock: true)
        next draft_only(ItemView) unless batch.status == "draft"
        limit = row.entry_line_id.try do |line_id|
          Candidates.open_amount(actor, row.card_code.to_s, batch.kind.to_s, line_id.to_i64)
            .try { |line| batch.kind == "debit" ? line.debit : line.credit }
        end
        errors = Items.item_errors(actor, batch, input, limit)
        if row.entry_line_id && Records.card(actor, input.card_code).try(&.code) != row.card_code
          errors << Records.error("card_code", "item.card.frozen")
        end
        next Result(ItemView).failure(errors) unless errors.empty?
        Items.apply_item(actor, batch, row, input).save!
        Items.renumber!(batch)
        Result(ItemView).success(Records.item_view(actor, Item.filter(id: id).first!))
      end
    end

    def self.remove_item(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, PREPARE)
      Transaction.run do
        row = Records.item!(actor, id)
        batch = Records.batch!(actor, row.batch_id!.to_i64, lock: true)
        next draft_only(Nil) unless batch.status == "draft"
        row.delete
        Items.renumber!(batch)
        Result(Nil).success(nil)
      end
    end

    def self.item(actor : Actor, id : Int64) : ItemView
      authorize!(actor, READ)
      Records.item_view(actor, Records.item!(actor, id))
    end

    # --- Validation ----------------------------------------------------------------

    # Contrôle complet du lot sans rien changer (ce que `prepare` exigera).
    def self.check_batch(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, READ)
      batch = Records.batch!(actor, id)
      errors = Preparation.errors(actor, batch, Item.filter(batch_id: id).order(:position).to_a)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    # Prépare le lot (D-SEPA-005) : contrôle complet, puis le lot est figé
    # en attente d'approbation ; séquences des prélèvements arrêtées.
    def self.prepare(actor : Actor, id : Int64) : Result(BatchView)
      authorize!(actor, PREPARE)
      Transaction.run do
        batch = Records.batch!(actor, id, lock: true)
        next draft_only(BatchView) unless batch.status == "draft"
        items = Item.filter(batch_id: id).order(:position).to_a
        errors = Preparation.errors(actor, batch, items)
        next Result(BatchView).failure(errors) unless errors.empty?
        Preparation.freeze!(batch, items)
        batch.status = "prepared"
        batch.prepared_by_id = actor.user_id
        batch.prepared_at = Partiduo::Config.now
        batch.save!
        Result(BatchView).success(Records.batch_view(actor, batch))
      end
    end

    # Approuve un lot préparé (D-SEPA-005) : en validation à deux, par une
    # autre personne que celle qui l'a préparé. Le fichier ISO 20022 est
    # produit, contrôlé (structure, et XSD officiel s'il est déposé), puis
    # conservé en pièce jointe par le socle. Exige aussi
    # `core.attachment.write`. Erreurs : `sepa.errors.approval.*`,
    # `.file.invalid`, celles de `prepare`, celles du socle.
    def self.approve(actor : Actor, id : Int64) : Result(BatchView)
      authorize!(actor, APPROVE)
      Guard.authorize!(actor, ATTACHMENT_PERMISSION)
      Transaction.run do
        batch = Records.batch!(actor, id, lock: true)
        next Result(BatchView).failure(Records.error(FieldError::BASE, "approval.not_prepared")) unless batch.status == "prepared"
        mode = Settings.view.approval_mode
        if mode == "dual" && (actor.user_id.nil? || actor.user_id == batch.prepared_by_id.try(&.to_i64))
          next Result(BatchView).failure(Records.error(FieldError::BASE, "approval.same_person"))
        end
        items = Item.filter(batch_id: id).order(:position).to_a
        errors = Preparation.errors(actor, batch, items)
        next Result(BatchView).failure(errors) unless errors.empty?
        account = Preparation.account(actor, batch, errors) || raise "compte du lot introuvable"
        now = Partiduo::Config.now
        message_id = XmlBuilder.message_id(id, now)
        addresses = Producer.addresses(items)
        content = XmlBuilder.build(XmlBuilder::Input.new(batch, items, account, Settings.view.creditor_identifier, message_id,
          now, addresses))
        problems = Producer.problems(content, batch.kind.to_s)
        unless problems.empty?
          next Result(BatchView).failure(Records.error(FieldError::BASE, "file.invalid",
            {"detail" => problems.first(5).join(" ; ")}))
        end
        view = Records.batch_view(actor, batch)
        stored = Partiduo::Api::Core.store_attachment(actor, Partiduo::Api::Core::AttachmentInput.new(
          view.filename, "application/xml", IO::Memory.new(content)))
        next Result(BatchView).failure(stored.errors) if stored.failure?
        batch.status = "approved"
        batch.approval_mode = mode
        batch.approved_by_id = actor.user_id
        batch.approved_at = now
        batch.message_id = message_id
        batch.attachment_id = stored.value!.id
        batch.file_sha256 = stored.value!.sha256
        batch.save!
        Result(BatchView).success(Records.batch_view(actor, batch))
      end
    end

    # Ramène en préparation un lot préparé ou approuvé (non émis) ; le
    # fichier d'un lot approuvé est retiré (il n'a pas été déposé).
    def self.reopen(actor : Actor, id : Int64) : Result(BatchView)
      authorize!(actor, PREPARE)
      Transaction.run do
        batch = Records.batch!(actor, id, lock: true)
        unless batch.status.in?("prepared", "approved")
          next Result(BatchView).failure(Records.error(FieldError::BASE, "batch.not_reopenable"))
        end
        attachment_id = batch.attachment_id.try(&.to_i64)
        Preparation.unfreeze!(Item.filter(batch_id: id).to_a)
        batch.status = "draft"
        batch.prepared_by_id = nil
        batch.prepared_at = nil
        batch.approved_by_id = nil
        batch.approved_at = nil
        batch.approval_mode = ""
        batch.message_id = ""
        batch.attachment_id = nil
        batch.file_sha256 = ""
        batch.save!
        if attachment_id && actor.can?(ATTACHMENT_PERMISSION)
          Partiduo::Api::Core.delete_attachment(actor, attachment_id)
        end
        Result(BatchView).success(Records.batch_view(actor, batch))
      end
    end

    # Confirme l'émission d'un lot approuvé (fichier déposé à la banque le
    # `issued_on`) : mandats mis à jour (séquence suivante, amendement
    # signalé), puis, selon le réglage, règlements passés (D-SEPA-010) —
    # sinon proposés (`post_settlements`). Le lot émis ne change plus.
    def self.confirm_issue(actor : Actor, id : Int64, issued_on : Time? = nil) : Result(SettlementReportView)
      authorize!(actor, APPROVE)
      result = Transaction.run do
        batch = Records.batch!(actor, id, lock: true)
        next Result(Batch).failure(Records.error(FieldError::BASE, "issue.not_approved")) unless batch.status == "approved"
        day = issued_on || Partiduo::Config.today
        if day > Partiduo::Config.today
          next Result(Batch).failure(Records.error("issued_on", "issue.future"))
        end
        batch.status = "issued"
        batch.issued_on = day
        batch.issued_by_id = actor.user_id
        batch.issued_at = Partiduo::Config.now
        batch.save!
        if batch.kind == "debit"
          Item.filter(batch_id: id).each do |row|
            row.mandate_id.try { |mandate_id| Mandates.record_collection!(Records.mandate!(mandate_id.to_i64, lock: true), batch.requested_on!) }
          end
        end
        Result(Batch).success(batch)
      end
      return Result(SettlementReportView).failure(result.errors) if result.failure?
      batch = result.value!
      return settle(actor, batch) if Settings.view.settlement_mode == "post" && actor.can?("accounting.entry.post")
      Result(SettlementReportView).success(SettlementReportView.new([] of ItemView, [] of ItemView, [] of ItemView))
    end

    # Passe les règlements restants d'un lot émis (D-SEPA-010), un par
    # paiement, jamais en double. Exige aussi `accounting.entry.post` et
    # l'écriture dans le journal.
    def self.post_settlements(actor : Actor, id : Int64) : Result(SettlementReportView)
      authorize!(actor, APPROVE)
      batch = Records.batch!(actor, id)
      return Result(SettlementReportView).failure(Records.error(FieldError::BASE, "settlement.not_issued")) unless batch.status == "issued"
      settle(actor, batch)
    end

    # Fichier produit, relu dans les pièces jointes du socle : nom, type et
    # contenu. Exige aussi `core.attachment.read`.
    def self.file(actor : Actor, id : Int64) : {String, String, Bytes}?
      authorize!(actor, READ)
      batch = Records.batch!(actor, id)
      attachment_id = batch.attachment_id.try(&.to_i64) || return
      view = Partiduo::Api::Core.attachment(actor, attachment_id)
      {view.filename, view.content_type, Partiduo::Api::Core.attachment_content(actor, attachment_id)}
    rescue Partiduo::Api::NotFound
      nil
    end

    # --- Tableau de bord -----------------------------------------------------------

    # Lots à approuver, à émettre, règlements à passer, dans les journaux
    # visibles ; `nil` si l'extension est inactive ou l'acteur sans droit.
    def self.tile(actor : Actor) : TileView?
      return unless Partiduo::Modules.active?(MODULE_CODE) && actor.can?(READ)
      ids = Records.visible_ledger_ids(actor)
      return TileView.new(0, 0, 0) if ids.empty?
      rows = Batch.filter(ledger_id__in: ids, status__in: %w[prepared approved issued]).to_a
      issued = rows.select(&.status.==("issued")).map(&.id!.to_i64)
      to_settle = issued.empty? ? 0 : Item.filter(batch_id__in: issued, settlement: "none").count.to_i32
      TileView.new(rows.count(&.status.==("prepared")), rows.count(&.status.==("approved")), to_settle)
    end

    # Compteur du menu : lots qui attendent l'acteur (à approuver ou à
    # émettre s'il approuve, rien sinon).
    def self.pending_count(actor : Actor) : Int64?
      view = tile(actor) || return
      return 0_i64 unless actor.can?(APPROVE)
      (view.to_approve + view.to_issue).to_i64
    end

    # --- Outils ----------------------------------------------------------------------

    private def self.authorize!(actor : Actor, permission : String) : Nil
      Guard.authorize!(actor, permission, module_code: MODULE_CODE)
    end

    private def self.draft_only(type : T.class) : Result(T) forall T
      Result(T).failure(Records.error(FieldError::BASE, "batch.not_draft"))
    end

    private def self.settle(actor : Actor, batch : Batch) : Result(SettlementReportView)
      rows = Item.filter(batch_id: batch.id, settlement: "none").order(:position).to_a
      posted, elsewhere, failed = Settlement.run(actor, batch, rows)
      debit = batch.kind == "debit"
      Result(SettlementReportView).success(SettlementReportView.new(
        Records.item_views(actor, posted, debit), Records.item_views(actor, elsewhere, debit),
        Records.item_views(actor, failed, debit)))
    end
  end
end
