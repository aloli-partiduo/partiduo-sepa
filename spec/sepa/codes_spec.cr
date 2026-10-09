# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Sepa::SpecSupport
private alias Api = Sepa::Api

describe "Contrôles SEPA : IBAN, BIC, ICS, références, jeu de caractères, jours ouvrés (D-SEPA-006, D-SEPA-008)" do
  it "contrôle l'IBAN par sa clé modulo 97 et la longueur de son pays" do
    [S::BANK_IBAN, S::SUPPLIER_IBAN, S::GERMAN_IBAN, S::BELGIAN_IBAN, S::POSTAL_IBAN].each do |iban|
      Api.iban_valid?(iban).should be_true
    end
    Api.iban_valid?("fr76 3000 6000 0112 3456 7890 189").should be_true
    Api.iban_valid?("FR7630006000011234567890188").should be_false
    Api.iban_valid?("FR763000600001123456789018").should be_false
    Api.iban_valid?("BE6853900754703").should be_false
    Api.iban_valid?("").should be_false
    Api.format_iban("FR7630006000011234567890189").should eq("FR76 3000 6000 0112 3456 7890 189")
    Api.mask_iban("FR7630006000011234567890189").should eq("FR76 **** **** 0189")
  end

  it "contrôle le BIC et l'identifiant créancier SEPA" do
    Api.bic_valid?("BDFEFRPPXXX").should be_true
    Api.bic_valid?("GEBABEBB").should be_true
    Api.bic_valid?("GEBABEB").should be_false
    Api.bic_valid?("1EBABEBB").should be_false
    Api.ics_valid?(S::ICS).should be_true
    Api.ics_valid?("FR72ABC123456").should be_true
    Api.ics_valid?("FR73ZZZ123456").should be_false
    Api.ics_valid?("BE68ZZZ0123456789").should be_true
  end

  it "reconnaît la référence RF et la communication structurée belge" do
    Sepa::Codes.reference_kind("RF18 5390 0754 7034").should eq("rf")
    Sepa::Codes.reference_kind("RF19 5390 0754 7034").should eq("text")
    Sepa::Codes.belgian_reference("+++090/9337/55493+++").should eq("090933755493")
    Sepa::Codes.reference_kind("+++090/9337/55494+++").should eq("text")
    Sepa::Codes.reference_kind("Facture 2026-114").should eq("text")
  end

  it "translittère les accents et remplace les caractères hors du jeu SEPA" do
    Api.transliterate("Société Générale & Cie — « Œuvre » n°5").should eq("Societe Generale + Cie - ' OEuvre ' n.5")
    Api.transliterate("Straße Ærø Łódź ç").should eq("Strasse AEro Lodz c")
    Api.transliterate("a@b_c; d€", 8).should eq("a b-c, d")
    Sepa::Charset.valid_identifier?("PD12-34").should be_true
    Sepa::Charset.valid_identifier?("/PD12").should be_false
    Sepa::Charset.valid_identifier?("PD//12").should be_false
    Sepa::Charset.valid_identifier?("PDé").should be_false
    Sepa::Charset.valid_identifier?("X" * 36).should be_false
  end

  it "ne retient que les jours ouvrés TARGET" do
    Sepa::Calendar.easter_sunday(2026).should eq(S.date("2026-04-05"))
    Sepa::Calendar.business_day?(S.date("2026-04-03")).should be_false
    Sepa::Calendar.business_day?(S.date("2026-04-06")).should be_false
    Sepa::Calendar.business_day?(S.date("2026-05-01")).should be_false
    Sepa::Calendar.business_day?(S.date("2026-10-10")).should be_false
    Sepa::Calendar.business_day?(S.date("2026-10-09")).should be_true
    Api.next_business_day(S.date("2026-12-25")).should eq(S.date("2026-12-28"))
    Api.default_date("transfer").should eq(S.date("2026-10-09"))
    Api.default_date("debit").should eq(S.date("2026-10-12"))
  end
end
