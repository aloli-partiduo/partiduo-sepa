# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Sepa::SpecSupport
private alias Api = Sepa::Api
private alias Acc = Partiduo::Api::Accounting

# Lot de virements avec les deux factures d'Alpha (dont une en retard) et
# celle de Beta, préparé par Bruno.
private def composed : {Api::BatchView, Acc::EntryView, Acc::EntryView}
  S.setup
  S.supplier("Fournitures Alpha", "ALPHA", city: "Lyon")
  S.supplier("Béta Logistique GmbH", "BETA", iban: S::GERMAN_IBAN, bic: "COBADEFFXXX")
  first = S.purchase("ALPHA", "100", "2026-09-10", due: "2026-10-10")
  second = S.purchase("BETA", "250.50", "2026-09-12")
  batch = S.batch
  lines = Api.candidates(S.preparer, batch.id).map(&.line_id)
  Api.add_open_items(S.preparer, batch.id, lines).value!.should eq(2)
  {Api.batch(S.reader, batch.id), first, second}
end

describe "Lots de virements fournisseurs (pain.001.001.09, D-SEPA-003, D-SEPA-009)" do
  it "propose les factures fournisseurs non lettrées, au montant exact, avec l'IBAN de la fiche" do
    S.setup
    S.supplier("Fournitures Alpha", "ALPHA")
    S.supplier("Sans IBAN", "NOIBAN", iban: "")
    invoice = S.purchase("ALPHA", "100", "2026-09-10", due: "2026-10-10")
    S.purchase("NOIBAN", "40")
    batch = S.batch
    candidates = Api.candidates(S.preparer, batch.id)
    candidates.map(&.card_code).sort!.should eq(["ALPHA", "NOIBAN"])
    alpha = candidates.find! { |item| item.card_code == "ALPHA" }
    alpha.amount.should eq(S.d("120"))
    alpha.line_id.should eq(S.line_of(invoice, "ALPHA").id)
    alpha.due_date.should eq(S.date("2026-10-10"))
    alpha.iban.should eq(S::SUPPLIER_IBAN)
    alpha.problem.should be_nil
    noiban = candidates.find! { |item| item.card_code == "NOIBAN" }
    noiban.problem.should eq("iban.blank")
    refused = Api.add_open_items(S.preparer, batch.id, [noiban.line_id])
    refused.error_keys.should eq(["sepa.errors.item.candidate_iban_blank"])
    Api.candidates(S.preparer, batch.id).size.should eq(2)
  end

  it "compose le lot : montant ouvert, communication, référence de bout en bout ; une écriture n'entre qu'une fois" do
    batch, first, _ = composed
    batch.items.size.should eq(2)
    batch.total.should eq(S.d("420.60"))
    alpha = batch.items.find! { |item| item.card_code == "ALPHA" }
    alpha.amount.should eq(S.d("120"))
    alpha.iban.should eq(S::SUPPLIER_IBAN)
    alpha.entry_id.should eq(first.id)
    alpha.remittance.should eq("#{first.receipt} Facture ALPHA")
    alpha.end_to_end_id.should eq("PD#{batch.id}-#{alpha.id}-#{first.receipt}")
    beta = batch.items.find! { |item| item.card_code == "BETA" }
    beta.name.should eq("Beta Logistique GmbH")
    beta.bic.should eq("COBADEFFXXX")
    Api.candidates(S.preparer, batch.id).should be_empty

    other = S.batch(label: "Autre")
    Api.add_open_items(S.preparer, other.id, [S.line_of(first, "ALPHA").id]).error_keys
      .should eq(["sepa.errors.item.line_unavailable"])
  end

  it "corrige un paiement : au plus le montant ouvert, au centime ; paiement saisi sans écriture" do
    batch, _, _ = composed
    alpha = batch.items.find! { |item| item.card_code == "ALPHA" }
    too_much = Api.update_item(S.preparer, alpha.id, Api::ItemInput.new(card_code: "ALPHA", amount: S.d("120.01")))
    too_much.error_keys.should eq(["sepa.errors.item.amount.over_open"])
    Api.update_item(S.preparer, alpha.id, Api::ItemInput.new(card_code: "ALPHA", amount: S.d("50.001")))
      .error_keys.should eq(["sepa.errors.item.amount.cents"])
    partial = Api.update_item(S.preparer, alpha.id, Api::ItemInput.new(card_code: "ALPHA", amount: S.d("60"),
      remittance: "RF18 5390 0754 7034")).value!
    partial.amount.should eq(S.d("60"))
    partial.reference_kind.should eq("rf")

    manual = Api.add_item(S.preparer, batch.id, Api::ItemInput.new(card_code: "BETA", amount: S.d("15"),
      remittance: "Acompte commande n°18")).value!
    manual.entry_line_id.should be_nil
    manual.remittance.should eq("Acompte commande n.18")
    manual.position.should eq(3)
    Api.add_item(S.preparer, batch.id, Api::ItemInput.new(card_code: "BETA", amount: S.d("15"), iban: "FR76 0000"))
      .error_keys.should eq(["sepa.errors.iban.invalid"])
    Api.remove_item(S.preparer, manual.id).value!
    Api.batch(S.reader, batch.id).items.map(&.position).should eq([1, 2])
  end

  it "refuse une date passée ou non ouvrée, un journal sans IBAN" do
    S.setup
    input = Api::BatchInput.new(kind: "transfer", ledger_id: S.bank.id, requested_on: S.date("2026-10-07"))
    Api.create_batch(S.preparer, input).error_keys.should eq(["sepa.errors.date.past"])
    holiday = Api.create_batch(S.preparer, input.copy_with(requested_on: S.date("2026-10-10")))
    holiday.error_keys.should eq(["sepa.errors.date.not_business_day"])
    holiday.errors.first.params["next"].should eq("2026-10-12")
    expect_raises(Partiduo::Api::Forbidden) { Api.create_batch(S.reader, input.copy_with(requested_on: S.date("2026-10-09"))) }

    S.supplier("Fournitures Alpha", "ALPHA")
    S.purchase("ALPHA", "100")
    batch = S.batch
    Api.add_open_items(S.preparer, batch.id, Api.candidates(S.preparer, batch.id).map(&.line_id)).value!
    S.bank_iban("")
    Api.prepare(S.preparer, batch.id).error_keys.should eq(["sepa.errors.ledger.iban_blank"])
    S.bank_iban(S::BANK_IBAN, S::BANK_BIC)
    Api.prepare(S.preparer, batch.id).value!.status.should eq("prepared")
  end

  it "prépare puis approuve (une personne) : fichier pain.001.001.09 contrôlé et conservé en pièce jointe" do
    batch, first, second = composed
    expect_raises(Partiduo::Api::Forbidden) { Api.approve(S.preparer, batch.id) }
    prepared = Api.prepare(S.preparer, batch.id).value!
    prepared.status.should eq("prepared")
    prepared.prepared_by_id.should eq(S.user_id("bruno@example.com"))
    Api.add_item(S.preparer, batch.id, Api::ItemInput.new(card_code: "BETA", amount: S.d("1"))).error_keys
      .should eq(["sepa.errors.batch.not_draft"])

    approved = Api.approve(S.accountant, batch.id).value!
    approved.status.should eq("approved")
    approved.approval_mode.should eq("single")
    approved.message_id.should eq("PDSEPA-#{batch.id}-20261008100000")
    attachment = Partiduo::Api::Core.attachment(S.accountant, present(approved.attachment_id))
    attachment.content_type.should eq("application/xml")
    attachment.filename.should eq("sepa-virements-#{batch.id}-20261009.xml")
    xml = S.xml(batch.id)
    xml.should contain(%(<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.001.001.09"))
    xml.should contain("<NbOfTxs>2</NbOfTxs>")
    xml.should contain("<CtrlSum>420.60</CtrlSum>")
    xml.should match(/<ReqdExctnDt>\s*<Dt>2026-10-09<\/Dt>/)
    xml.should contain("<Nm>Atelier Brunet SARL</Nm>")
    xml.should contain("<IBAN>#{S::BANK_IBAN}</IBAN>")
    xml.should contain("<BICFI>BDFEFRPPXXX</BICFI>")
    xml.should contain(%(<InstdAmt Ccy="EUR">120.00</InstdAmt>))
    xml.should contain(%(<InstdAmt Ccy="EUR">300.60</InstdAmt>))
    xml.should contain("<EndToEndId>PD#{batch.id}-")
    xml.should contain("<TwnNm>Lyon</TwnNm>")
    xml.should contain("<AdrLine>12 rue de l'Eglise</AdrLine>")
    xml.should contain("<BICFI>COBADEFFXXX</BICFI>")
    xml.should contain("<Ustrd>#{first.receipt} Facture ALPHA</Ustrd>")
    xml.should contain("<Ustrd>#{second.receipt} Facture BETA</Ustrd>")
    xml.should contain("<BtchBookg>true</BtchBookg>")
    Sepa::Structure.problems(xml, "transfer").should be_empty
  end

  it "en validation à deux, refuse que le préparateur approuve ; une autre personne approuve" do
    batch, _, _ = composed
    S.settings(approval_mode: "dual")
    preparer_and_approver = S.actor("bruno@example.com", [Api::READ, Api::PREPARE, Api::APPROVE] + S::CORE_PERMISSIONS)
    Api.prepare(preparer_and_approver, batch.id).value!
    Api.approve(preparer_and_approver, batch.id).error_keys.should eq(["sepa.errors.approval.same_person"])
    approved = Api.approve(S.accountant, batch.id).value!
    approved.approval_mode.should eq("dual")
    approved.approved_by_id.should eq(S.user_id("alice@example.com"))

    reopened = Api.reopen(S.preparer, batch.id).value!
    reopened.status.should eq("draft")
    reopened.attachment_id.should be_nil
    expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Core.attachment(S.accountant, present(approved.attachment_id)) }
  end

  it "refuse d'approuver un lot dont une facture a été réglée entre-temps" do
    batch, first, _ = composed
    Api.prepare(S.preparer, batch.id).value!
    line = S.line_of(first, "ALPHA")
    payment = Acc::FinancialInput.new(ledger_id: S.bank.id, date: S.date("2026-10-01"),
      lines: [Acc::PaymentLineInput.new(S.d("-120"), card: "ALPHA", match_line_ids: [line.id])])
    Acc.post_financial(S.system, payment).value!
    refused = Api.approve(S.accountant, batch.id)
    refused.error_keys.should eq(["sepa.errors.item.line_closed"])
    refused.errors.first.field.should eq("items[2].entry_line_id")
  end
end
