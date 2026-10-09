# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Sepa::SpecSupport
private alias Api = Sepa::Api
private alias Acc = Partiduo::Api::Accounting

# Deux clients sous mandat (Leroux récurrent, Morel ponctuel), une facture
# chacun, l'ICS réglé.
private def debit_setup : {Api::MandateView, Api::MandateView}
  S.setup
  S.settings(creditor_identifier: "fr72 zzz 123456")
  S.customer("Menuiserie Leroux", "LEROUX")
  S.customer("Atelier Morel", "MOREL")
  S.customer("Sans mandat", "NOMANDATE")
  leroux = S.mandate("LEROUX", rum: "LEROUX-2026-01")
  morel = S.mandate("MOREL", iban: S::POSTAL_IBAN, kind: "one_off", signed: "2026-09-01")
  S.sale("LEROUX", "500", "2026-09-20")
  S.sale("MOREL", "80", "2026-09-21")
  S.sale("NOMANDATE", "10", "2026-09-22")
  {leroux, morel}
end

private def collect(day : String = "2026-10-12") : Api::BatchView
  batch = S.batch("debit", day, label: "Prélèvements")
  Api.add_open_items(S.preparer, batch.id, Api.candidates(S.preparer, batch.id).map(&.line_id)).value!
  Api.prepare(S.preparer, batch.id).value!
  Api.approve(S.accountant, batch.id).value!
end

describe "Prélèvements SEPA Core sur mandats (pain.008.001.08, D-SEPA-007)" do
  it "enregistre les mandats : RUM unique au jeu SEPA, IBAN contrôlé, RUM proposée" do
    S.setup
    S.customer("Menuiserie Leroux", "LEROUX")
    created = S.mandate("LEROUX")
    created.rum.should eq("LEROUX-20260115-1")
    created.next_sequence.should eq("FRST")
    created.iban_masked.should eq("BE68 **** **** 7034")
    created.expires_on.should eq(S.date("2029-01-15"))
    input = Api::MandateInput.new(card_code: "LEROUX", signed_on: S.date("2026-02-01"), iban: "BE68539007547035",
      rum: "leroux-20260115-1")
    Api.create_mandate(S.accountant, input).error_keys.sort.should eq(["sepa.errors.iban.invalid", "sepa.errors.mandate.rum.taken"])
    Api.create_mandate(S.accountant, input.copy_with(iban: S::BELGIAN_IBAN, rum: "/MANDAT")).error_keys
      .should eq(["sepa.errors.mandate.rum.invalid"])
    Api.create_mandate(S.accountant, input.copy_with(iban: S::BELGIAN_IBAN, rum: "", signed_on: S.date("2026-11-01")))
      .error_keys.should eq(["sepa.errors.mandate.signed_on.future"])
    expect_raises(Partiduo::Api::Forbidden) { Api.create_mandate(S.preparer, input) }
    Api.mandates(S.reader).map(&.card_code).should eq(["LEROUX"])
  end

  it "propose les factures clients des seuls clients sous mandat actif" do
    debit_setup
    batch = S.batch("debit", "2026-10-12")
    Api.candidates(S.preparer, batch.id).map(&.card_code).should eq(["LEROUX", "MOREL"])
    Api.add_item(S.preparer, batch.id, Api::ItemInput.new(card_code: "NOMANDATE", amount: S.d("12")))
      .error_keys.should eq(["sepa.errors.item.mandate.none"])
    input = Api::BatchInput.new(kind: "debit", ledger_id: S.bank.id, requested_on: S.date("2026-10-08"))
    Api.create_batch(S.preparer, input).error_keys.should eq(["sepa.errors.date.too_soon"])
  end

  it "produit un pain.008.001.08 : séquences FRST et OOFF, ICS, mandat, échéance" do
    leroux, _ = debit_setup
    batch = collect
    xml = S.xml(batch.id)
    xml.should contain(%(<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.008.001.08"))
    xml.should contain("<PmtMtd>DD</PmtMtd>")
    xml.should contain("<SeqTp>FRST</SeqTp>")
    xml.should contain("<SeqTp>OOFF</SeqTp>")
    xml.should_not contain("<SeqTp>RCUR</SeqTp>")
    xml.should contain("<ReqdColltnDt>2026-10-12</ReqdColltnDt>")
    xml.should contain("<Id>FR72ZZZ123456</Id>")
    xml.should contain("<MndtId>LEROUX-2026-01</MndtId>")
    xml.should contain("<DtOfSgntr>2026-01-15</DtOfSgntr>")
    xml.should contain(%(<InstdAmt Ccy="EUR">600.00</InstdAmt>))
    xml.should contain("<IBAN>#{S::BELGIAN_IBAN}</IBAN>")
    xml.should contain("<Othr>\n              <Id>NOTPROVIDED</Id>")
    xml.should contain("<CtrlSum>696.00</CtrlSum>")
    xml.should contain("<LclInstrm>")
    Sepa::Structure.problems(xml, "debit").should be_empty
    batch.filename.should eq("sepa-prelevements-#{batch.id}-20261012.xml")

    Api.confirm_issue(S.accountant, batch.id).value!.posted.size.should eq(2)
    Api.mandate(S.reader, leroux.id).next_sequence.should eq("RCUR")
    Api.mandates(S.reader, "MOREL").first.status.should eq("used")
    entry = Acc.entries(S.accountant, Acc::EntryQuery.new(ledger_id: S.bank.id, card: "LEROUX")).first
    entry.lines.find! { |line| line.card_code == "LEROUX" }.side.should eq(Acc::Side::Credit)
  end

  it "signale à la banque l'IBAN changé après un premier prélèvement (amendement), en RCUR" do
    leroux, _ = debit_setup
    Api.confirm_issue(S.accountant, collect.id).value!
    S.sale("LEROUX", "100", "2026-10-01")
    change = Api::MandateInput.new(card_code: "LEROUX", signed_on: S.date("2026-01-15"), iban: S::SUPPLIER_IBAN,
      rum: "LEROUX-2026-01")
    amended = Api.update_mandate(S.accountant, leroux.id, change).value!
    amended.amended.should be_true
    Api.update_mandate(S.accountant, leroux.id, change.copy_with(rum: "AUTRE")).error_keys.should eq(["sepa.errors.mandate.rum.frozen"])

    second = collect("2026-10-13")
    xml = S.xml(second.id)
    xml.should contain("<SeqTp>RCUR</SeqTp>")
    xml.should contain("<AmdmntInd>true</AmdmntInd>")
    xml.should match(/<OrgnlDbtrAcct>\s*<Id>\s*<IBAN>#{S::BELGIAN_IBAN}<\/IBAN>/)
    xml.should contain("<IBAN>#{S::SUPPLIER_IBAN}</IBAN>")
    Sepa::Structure.problems(xml, "debit").should be_empty
    Api.confirm_issue(S.accountant, second.id).value!
    Api.mandate(S.reader, leroux.id).amended.should be_false
  end

  it "refuse un mandat révoqué ou expiré, et l'ICS absent" do
    leroux, _ = debit_setup
    S.settings(creditor_identifier: "")
    batch = S.batch("debit", "2026-10-12")
    Api.add_open_items(S.preparer, batch.id, Api.candidates(S.preparer, batch.id).map(&.line_id)).value!
    Api.prepare(S.preparer, batch.id).error_keys.should eq(["sepa.errors.settings.ics_blank"])
    S.settings(creditor_identifier: S::ICS)
    Api.revoke_mandate(S.accountant, leroux.id).value!.status.should eq("revoked")
    Api.prepare(S.preparer, batch.id).error_keys.should eq(["sepa.errors.item.mandate_inactive"])
    Api.delete_mandate(S.accountant, leroux.id).error_keys.should eq(["sepa.errors.mandate.in_use"])

    Sepa::Mandate.filter(id: leroux.id).update(status: "active", revoked_on: nil, signed_on: S.date("2023-09-01"))
    expired = Api.prepare(S.preparer, batch.id)
    expired.error_keys.should eq(["sepa.errors.item.mandate_expired"])
    expired.errors.first.params["date"].should eq("2026-09-01")
  end

  it "refuse les prélèvements dans un dossier foyer" do
    S.setup
    Partiduo::Core::Settings.all.update(kind: "household")
    input = Api::BatchInput.new(kind: "debit", ledger_id: S.bank.id, requested_on: S.date("2026-10-12"))
    Api.create_batch(S.preparer, input).error_keys.should eq(["sepa.errors.batch.debit_household"])
    Api.create_batch(S.preparer, input.copy_with(kind: "transfer")).success?.should be_true
  end
end
