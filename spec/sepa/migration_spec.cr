# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Sepa::SpecSupport
private alias Api = Sepa::Api

private def sql(text : String) : Nil
  Marten::DB::Connection.default.open(&.exec(text))
end

private def scalar(text : String) : String
  Marten::DB::Connection.default.open(&.scalar(text)).to_s
end

# Ramène l'extension avant la migration 0002 (réglages d'avant 0.1.3), écrit
# les anciennes données par `fill`, puis rejoue la migration.
private def replay_0002(&fill : -> Nil) : Nil
  # Un exécuteur par étape : chacun lit à sa création les migrations
  # appliquées.
  runner = -> { Marten::DB::Management::Migrations::Runner.new(Marten::DB::Connection.default) }
  app = Marten.apps.get("sepa")
  # Le journal des migrations est vidé entre deux exemples avec les autres
  # tables : le schéma, lui, est à jour ; on le réinscrit sans rien exécuter.
  runner.call.execute(fake: true)
  runner.call.execute(app, "0001_create_sepa")
  fill.call
  runner.call.execute(app, "0002_company_settings_approvals")
end

describe "Migration 0002 : réglages repris par la société, lots préparés repassés en préparation (D-SEPA-016, D-SEPA-017)" do
  it "reprend l'ICS et la validation à deux dans la société, sans rien perdre, et rouvre les lots en attente d'approbation" do
    S.setup
    bruno = S.user_id("bruno@example.com")
    replay_0002 do
      sql("INSERT INTO sepa_setting (approval_mode, settlement_mode, batch_booking, creditor_identifier, created_at, updated_at) " \
          "VALUES ('dual', 'propose', FALSE, '#{S::ICS}', now(), now())")
      sql("INSERT INTO sepa_batch (id, kind, ledger_id, status, label, requested_on, batch_booking, message_id, file_sha256, " \
          "approval_mode, created_by_id, prepared_by_id, prepared_at, created_at, updated_at) VALUES (900, 'debit', " \
          "#{S.bank.id}, 'prepared', 'Ancien', '2026-10-12', TRUE, '', '', '', #{bruno}, #{bruno}, now(), now(), now())")
      sql("INSERT INTO sepa_item (batch_id, position, card_code, name, iban, amount, sequence_type, mandate_rum, " \
          "mandate_signed_on, original_iban, settlement, created_at, updated_at) VALUES (900, 1, 'LEROUX', 'Leroux', " \
          "'#{S::BELGIAN_IBAN}', 50, 'FRST', 'LEROUX-1', '2026-01-15', '#{S::GERMAN_IBAN}', 'none', now(), now())")
    end
    company = Partiduo::Api::Core.settings(S.system)
    company.creditor_identifier.should eq(S::ICS)
    company.approval_mode.should eq("dual")
    Partiduo::Api::Approvals.log(S.system).map { |event| {event.action, event.detail} }
      .should contain({"policy.changed", "single/5 → dual/5 (partiduo-sepa 0002)"})
    settings = Api.settings(S.accountant)
    settings.settlement_mode.should eq("propose")
    settings.batch_booking.should be_false
    settings.creditor_identifier.should eq(S::ICS)
    settings.dual?.should be_true
    settings.legacy_creditor_identifier.should eq("")
    scalar("SELECT count(*) FROM information_schema.columns WHERE table_name = 'sepa_setting' " \
           "AND column_name IN ('approval_mode', 'creditor_identifier')").should eq("0")

    batch = Api.batch(S.accountant, 900)
    batch.status.should eq("draft")
    batch.prepared_by_id.should be_nil
    item = batch.items.first
    item.sequence_type.should eq("")
    item.mandate_rum.should eq("")
    item.amended.should be_false
  end

  it "garde l'ICS de l'extension quand la société en a un autre, et ne relâche pas une validation à deux" do
    S.setup
    S.company(creditor_identifier: "BE68ZZZ0123456789", approval_mode: "dual")
    replay_0002 do
      sql("INSERT INTO sepa_setting (approval_mode, settlement_mode, batch_booking, creditor_identifier, created_at, updated_at) " \
          "VALUES ('single', 'post', TRUE, '#{S::ICS}', now(), now())")
    end
    company = Partiduo::Api::Core.settings(S.system)
    company.creditor_identifier.should eq("BE68ZZZ0123456789")
    company.approval_mode.should eq("dual")
    settings = Api.settings(S.accountant)
    settings.creditor_identifier.should eq("BE68ZZZ0123456789")
    settings.legacy_creditor_identifier.should eq(S::ICS)

    input = Api::SettingsInput.new(settlement_mode: "post", discard_legacy_creditor_identifier: true)
    Api.update_settings(S.accountant, input).value!.legacy_creditor_identifier.should eq("")
  end

  it "n'écrit rien dans un dossier neuf" do
    S.setup
    replay_0002 { }
    company = Partiduo::Api::Core.settings(S.system)
    company.creditor_identifier.should eq("")
    company.approval_mode.should eq("single")
    Api.settings(S.accountant).stored.should be_false
  end
end
