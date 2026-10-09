# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Sepa::SpecSupport
private alias Api = Sepa::Api
private alias Acc = Partiduo::Api::Accounting

# Lot de virements approuvé : facture d'Alpha (120 TTC) et de Beta (60 TTC).
private def approved : {Api::BatchView, Acc::EntryView, Acc::EntryView}
  S.setup
  S.supplier("Fournitures Alpha", "ALPHA")
  S.supplier("Beta", "BETA", iban: S::BELGIAN_IBAN)
  first = S.purchase("ALPHA", "100", "2026-09-10")
  second = S.purchase("BETA", "50", "2026-09-11")
  batch = S.batch
  Api.add_open_items(S.preparer, batch.id, Api.candidates(S.preparer, batch.id).map(&.line_id)).value!
  Api.prepare(S.preparer, batch.id).value!
  {Api.approve(S.accountant, batch.id).value!, first, second}
end

describe "Émission confirmée et règlements par le contrat de la Comptabilité (D-SEPA-010, D-SEPA-011)" do
  it "passe un règlement par paiement, lettré avec la facture, fichier en pièce jointe" do
    batch, first, _ = approved
    report = Api.confirm_issue(S.accountant, batch.id, S.date("2026-10-08")).value!
    report.posted.size.should eq(2)
    report.failed.should be_empty
    view = Api.batch(S.reader, batch.id)
    view.status.should eq("issued")
    view.issued_on.should eq(S.date("2026-10-08"))
    view.to_settle_count.should eq(0)
    alpha = view.items.find! { |item| item.card_code == "ALPHA" }
    alpha.settlement.should eq("posted")
    entry = Acc.entry(S.accountant, present(alpha.settlement_entry_id))
    entry.ledger_code.should eq("F01")
    entry.date.should eq(S.date("2026-10-09"))
    entry.source.should eq("sepa:item:#{alpha.id}")
    entry.attachment_id.should eq(batch.attachment_id)
    supplier = entry.lines.find! { |line| line.card_code == "ALPHA" }
    {supplier.side, supplier.amount}.should eq({Acc::Side::Debit, S.d("120")})
    present(supplier.matching_id).should eq(present(Acc.entry(S.accountant, first.id).lines.find! { |line| line.card_code == "ALPHA" }.matching_id))
    Acc.account_statement(S.accountant, Acc::StatementQuery.new(card: "ALPHA")).remaining.should eq(S.d("0"))

    again = Api.post_settlements(S.accountant, batch.id).value!
    again.posted.should be_empty
    Acc.entries(S.accountant, Acc::EntryQuery.new(source: "sepa:item:#{alpha.id}")).size.should eq(1)
  end

  it "en mode « proposer », ne passe rien à l'émission ; jamais deux fois une facture réglée ailleurs" do
    batch, first, _ = approved
    S.settings(settlement_mode: "propose")
    Api.confirm_issue(S.accountant, batch.id).value!.posted.should be_empty
    Api.batch(S.reader, batch.id).to_settle_count.should eq(2)
    Api.tile(S.accountant).should eq(Api::TileView.new(0, 0, 2))

    # La facture d'Alpha est réglée par le relevé importé, hors du lot.
    line = S.line_of(first, "ALPHA")
    Acc.post_financial(S.system, Acc::FinancialInput.new(ledger_id: S.bank.id, date: S.date("2026-10-09"),
      lines: [Acc::PaymentLineInput.new(S.d("-120"), card: "ALPHA", match_line_ids: [line.id])])).value!

    report = Api.post_settlements(S.accountant, batch.id).value!
    report.posted.map(&.card_code).should eq(["BETA"])
    report.elsewhere.map(&.card_code).should eq(["ALPHA"])
    Acc.entries(S.accountant, Acc::EntryQuery.new(ledger_id: S.bank.id, card: "ALPHA")).size.should eq(1)
    Api.batch(S.reader, batch.id).to_settle_count.should eq(0)
  end

  it "garde sur le paiement le refus de la Comptabilité, puis le passe une fois corrigé" do
    batch, _, _ = approved
    S.settings(settlement_mode: "propose")
    Api.confirm_issue(S.accountant, batch.id).value!
    poster = S.actor("alice@example.com", [Api::READ, Api::APPROVE, "accounting.ledger.read", "accounting.entry.read",
                                           "cards.card.read"])
    expect_raises(Partiduo::Api::Forbidden) { Api.post_settlements(poster, batch.id) }

    Sepa::Item.filter(batch_id: batch.id, card_code: "BETA").update(card_code: "DISPARU")
    report = Api.post_settlements(S.accountant, batch.id).value!
    report.posted.map(&.card_code).should eq(["ALPHA"])
    report.failed.size.should eq(1)
    present(report.failed.first.error).key.should eq("sepa.errors.item.card.unknown")
    Sepa::Item.filter(batch_id: batch.id, card_code: "DISPARU").update(card_code: "BETA")
    Api.post_settlements(S.accountant, batch.id).value!.posted.map(&.card_code).should eq(["BETA"])
  end

  it "rend à passer le paiement dont le règlement est extourné (entry.cancelled)" do
    batch, _, _ = approved
    Api.confirm_issue(S.accountant, batch.id).value!
    alpha = Api.batch(S.reader, batch.id).items.find! { |item| item.card_code == "ALPHA" }
    entry_id = present(alpha.settlement_entry_id)
    Acc.cancel_entry(S.accountant, Acc::CancelEntryInput.new(entry_id: entry_id)).value!
    reverted = Api.item(S.reader, alpha.id)
    reverted.settlement.should eq("none")
    reverted.reversed_entry_id.should eq(entry_id)
    reverted.settlement_entry_id.should be_nil
    Api.post_settlements(S.accountant, batch.id).value!.posted.size.should eq(1)
    Api.item(S.reader, alpha.id).settlement.should eq("posted")
  end

  it "refuse d'émettre un lot non approuvé ou à une date future, et garde le lot émis" do
    batch, _, _ = approved
    Api.confirm_issue(S.accountant, batch.id, S.date("2026-10-09")).error_keys.should eq(["sepa.errors.issue.future"])
    Api.confirm_issue(S.accountant, batch.id).value!
    Api.confirm_issue(S.accountant, batch.id).error_keys.should eq(["sepa.errors.issue.not_approved"])
    Api.reopen(S.preparer, batch.id).error_keys.should eq(["sepa.errors.batch.not_reopenable"])
    Api.delete_batch(S.preparer, batch.id).error_keys.should eq(["sepa.errors.batch.not_deletable"])
    S.xml(batch.id).should contain("<MsgId>#{batch.message_id}</MsgId>")
  end
end
