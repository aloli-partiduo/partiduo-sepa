# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Sepa::SpecSupport
private alias Api = Sepa::Api

private def transfer_xml : String
  S.setup
  S.supplier("Société Générale d'Équipement & Fils", "SGE", city: "Évry")
  S.purchase("SGE", "1000.10")
  batch = S.batch
  Api.add_open_items(S.preparer, batch.id, Api.candidates(S.preparer, batch.id).map(&.line_id)).value!
  item = Api.batch(S.reader, batch.id).items.first
  Api.update_item(S.preparer, item.id, Api::ItemInput.new(card_code: "SGE", amount: item.amount,
    remittance: "+++090/9337/55493+++")).value!
  Api.prepare(S.preparer, batch.id).value!
  S.xml(Api.approve(S.accountant, batch.id).value!.id)
end

describe "Fichiers ISO 20022 : contrôle structurel et XSD déposé (D-SEPA-001, D-SEPA-012)" do
  it "translittère les noms et adresses, écrit une communication structurée belge" do
    xml = transfer_xml
    xml.should contain("<Nm>Societe Generale d'Equipement + Fils</Nm>")
    xml.should contain("<TwnNm>Evry</TwnNm>")
    xml.should contain(%(<InstdAmt Ccy="EUR">1200.12</InstdAmt>))
    xml.should match(/<Strd>\s*<CdtrRefInf>\s*<Tp>\s*<CdOrPrtry>\s*<Cd>SCOR<\/Cd>\s*<\/CdOrPrtry>\s*<Issr>BBA<\/Issr>\s*<\/Tp>\s*<Ref>090933755493<\/Ref>/)
    xml.should_not contain("<CdtrAgt>")
    Sepa::Structure.problems(xml, "transfer").should be_empty
  end

  it "relève les écarts de structure, de valeurs et de totaux" do
    xml = transfer_xml
    Sepa::Structure.problems(xml, "debit").first.should contain("espace de noms")
    totals = Sepa::Structure.problems(xml.sub("<CtrlSum>1200.12</CtrlSum>", "<CtrlSum>1200.13</CtrlSum>"), "transfer")
    totals.should eq(["GrpHdr : CtrlSum 1200.13 au lieu de 1200.12"])
    iban = Sepa::Structure.problems(xml.sub(S::SUPPLIER_IBAN, "FR7630006000011234567890188"), "transfer")
    iban.first.should contain("IBAN invalide")
    order = Sepa::Structure.problems(xml.sub(%r{<ChrgBr>SLEV</ChrgBr>}, "").sub("<PmtMtd>TRF</PmtMtd>", "<PmtMtd>TRF</PmtMtd><ChrgBr>SLEV</ChrgBr>"), "transfer")
    order.any?(&.includes?("mal placé")).should be_true
    accents = Sepa::Structure.problems(xml.sub("<TwnNm>Evry</TwnNm>", "<TwnNm>Évry</TwnNm>"), "transfer")
    accents.first.should contain("hors du jeu SEPA")
    Sepa::Structure.problems("<pas du xml", "transfer").first.should start_with("XML illisible")
  end

  it "valide contre un XSD déposé par l'exploitant (liaison libxml2), sans rien exiger s'il manque" do
    xml = transfer_xml
    directory = File.join(S::FIXTURES, "xsd-minimal")
    Sepa::Schema.problems(xml, Api::TRANSFER_SCHEMA, nil).should be_nil
    Sepa::Schema.problems(xml, Api::DEBIT_SCHEMA, directory).should be_nil
    Sepa::Schema.problems(xml, Api::TRANSFER_SCHEMA, directory).should eq([] of String)
    long_id = xml.sub(/<MsgId>[^<]+<\/MsgId>/, "<MsgId>#{"X" * 40}</MsgId>")
    refused = present(Sepa::Schema.problems(long_id, Api::TRANSFER_SCHEMA, directory))
    refused.size.should eq(1)
    refused.first.should contain("MsgId")
  end
end
