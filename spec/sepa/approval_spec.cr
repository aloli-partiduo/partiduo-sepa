# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Sepa::SpecSupport
private alias Api = Sepa::Api
private alias Approvals = Partiduo::Api::Approvals

# Lot de virements préparé par Bruno (une facture d'Alpha), donc soumis au
# service d'approbation du socle.
private def submitted : {Api::BatchView, Approvals::ApprovalView}
  S.setup
  S.supplier("Fournitures Alpha", "ALPHA")
  S.purchase("ALPHA", "100", "2026-09-10")
  batch = S.batch
  Api.add_open_items(S.preparer, batch.id, Api.candidates(S.preparer, batch.id).map(&.line_id)).value!
  prepared = Api.prepare(S.preparer, batch.id).value!
  {prepared, present(Api.approval(S.preparer, batch.id))}
end

describe "Double validation par le service d'approbation du socle (A-SEPA-3, D-SEPA-017)" do
  it "soumet le lot préparé : objet, empreinte, montant, permission, au nom du préparateur" do
    batch, request = submitted
    request.pending?.should be_true
    request.module_code.should eq("SEPA")
    request.kind.should eq("batch")
    request.subject.should eq("batch:#{batch.id}")
    request.permission.should eq("sepa.approve")
    request.amount.should eq(S.d("120"))
    request.currency_code.should eq("EUR")
    request.requested_by_id.should eq(S.user_id("bruno@example.com"))
    request.summary.should eq("Lot SEPA n° #{batch.id} : Virements au 2026-10-09 · Fournisseurs octobre")
    request.details["sepa.approval.details.count"].should eq("1")
    request.details["sepa.approval.details.schema"].should eq("pain.001.001.09")
    request.digest.size.should eq(64)
    Approvals.pending(S.accountant, "SEPA").map(&.id).should eq([request.id])
    Api.tile(S.accountant).try(&.to_approve).should eq(1)
    # Le compteur de l'extension ne compte plus ce que « Approbations » compte.
    Api.pending_count(S.accountant).should eq(0)
  end

  it "exécute le lot approuvé depuis l'écran commun : fichier produit, approbation consommée une fois" do
    batch, request = submitted
    approved = Approvals.approve(S.accountant, request.id, "Vu").value!
    approved.approved?.should be_true
    approved.consumed?.should be_true
    view = Api.batch(S.reader, batch.id)
    view.status.should eq("approved")
    view.approval_mode.should eq("single")
    view.approved_by_id.should eq(S.user_id("alice@example.com"))
    S.xml(batch.id).should contain("<CtrlSum>120.00</CtrlSum>")
    Api.pending_count(S.accountant).should eq(1)
    # Une approbation ne sert qu'une fois.
    again = Approvals.consume(S.accountant, request.id, Approvals::ConsumeInput.new("SEPA", "batch", request.subject, request.digest))
    again.error_keys.should eq(["core.errors.approval.already_consumed"])
  end

  it "exige une authentification forte récente pour approuver ; le lot reste à approuver" do
    batch, _ = submitted
    stale = S.actor("alice@example.com", [Api::READ, Api::PREPARE, Api::APPROVE] + S::CORE_PERMISSIONS,
      strong_auth_at: Time.utc - 2.hours)
    Api.approve(stale, batch.id).error_keys.should eq(["core.errors.approval.reauthentication_required"])
    Api.batch(S.reader, batch.id).status.should eq("prepared")
    Api.approval(S.accountant, batch.id).try(&.pending?).should be_true
  end

  it "n'exécute pas un lot modifié après sa soumission (empreinte) ; la demande reste en attente" do
    batch, request = submitted
    # Le compte du donneur d'ordre change entre la soumission et la décision.
    S.bank_iban(S::GERMAN_IBAN, "COBADEFFXXX")
    Approvals.approve(S.accountant, request.id).error_keys.should eq(["sepa.errors.approval.changed"])
    Api.batch(S.reader, batch.id).status.should eq("prepared")
    Approvals.approval(S.accountant, request.id).pending?.should be_true
    # Un paiement modifié en base, de même.
    S.bank_iban(S::BANK_IBAN, S::BANK_BIC)
    Sepa::Item.filter(batch_id: batch.id).update(amount: S.d("99"))
    Approvals.approve(S.accountant, request.id).error_keys.should eq(["sepa.errors.approval.changed"])
    # Et le service refuse d'exécuter une autre empreinte que celle approuvée.
    Approvals.consume(S.accountant, request.id, Approvals::ConsumeInput.new("SEPA", "batch", request.subject, "0" * 64))
      .error_keys.should eq(["core.errors.approval.not_approved"])
    # Rouvrir retire la demande ; préparer de nouveau en soumet une autre.
    Api.reopen(S.preparer, batch.id).value!
    Approvals.approval(S.accountant, request.id).status.should eq("cancelled")
    Api.prepare(S.preparer, batch.id).value!
    renewed = present(Api.approval(S.accountant, batch.id))
    renewed.id.should_not eq(request.id)
    renewed.amount.should eq(S.d("99"))
    Api.approve(S.accountant, batch.id).value!.status.should eq("approved")
  end

  it "retire la demande d'un lot préparé supprimé ; un lot rejeté reste préparé, à rouvrir" do
    batch, request = submitted
    Approvals.reject(S.accountant, request.id, "Mauvais compte").value!
    Api.batch(S.reader, batch.id).status.should eq("prepared")
    Api.approve(S.accountant, batch.id).error_keys.should eq(["sepa.errors.approval.not_submitted"])
    Api.approval(S.preparer, batch.id).try(&.comment).should eq("Mauvais compte")
    Api.reopen(S.preparer, batch.id).value!
    Api.prepare(S.preparer, batch.id).value!
    pending = present(Api.approval(S.preparer, batch.id))
    Api.delete_batch(S.preparer, batch.id).value!
    Approvals.approval(S.accountant, pending.id).status.should eq("cancelled")
  end

  it "refuse l'exécution à qui ne peut pas conserver le fichier ; la demande reste en attente" do
    batch, request = submitted
    approver = S.actor("alice@example.com", [Api::READ, Api::APPROVE, "accounting.ledger.read", "accounting.entry.read",
                                             "cards.card.read"])
    Approvals.approve(approver, request.id).error_keys.should eq(["sepa.errors.approval.attachment_permission"])
    Api.batch(S.reader, batch.id).status.should eq("prepared")
    Approvals.approval(S.accountant, request.id).pending?.should be_true
  end
end
