# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Sepa::SpecSupport
private alias Api = Sepa::Api

private def menu_routes(entries : Array(Partiduo::Api::Modules::MenuView)) : Array(String?)
  entries.flat_map { |entry| [entry.route] + menu_routes(entry.children) }
end

describe "Extension SEPA : manifeste et activation (ADR-003 D2)" do
  it "déclare une extension conforme au contrat du cœur, qui dépend de la Comptabilité, sans incompatibilité" do
    manifest = Partiduo::Modules[Sepa::CODE]
    manifest.kind.should eq(Partiduo::Modules::Kind::Extension)
    manifest.version.should eq(Sepa::VERSION)
    Sepa::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
    manifest.requires_core.should eq("~> 0.1")
    manifest.permissions.should eq(["sepa.read", "sepa.prepare", "sepa.approve", "sepa.admin"])
    manifest.depends_on.should eq(["ACCOUNTING"])
    manifest.incompatible_with.should be_empty
    manifest.subscribed_events.should eq(["entry.cancelled"])
    manifest.uis.map(&.path).should eq(["ui/bulma"])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route} }.should eq([
      {"SEPA", nil, nil},
      {"SEPA_BATCHES", "SEPA", "sepa:batches"},
      {"SEPA_NEW", "SEPA", "sepa:batch_new"},
      {"SEPA_MANDATES", "SEPA", "sepa:mandates"},
      {"SEPA_SETTINGS", "SETTINGS", "sepa:settings"},
    ])
    Partiduo::Modules.structure_errors.should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Sepa::CODE, "ACCOUNTING"}).should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Sepa::CODE}).should eq(["SEPA requiert ACCOUNTING, inactif"])
  end

  it "traduit son nom, ses permissions et ses menus en fr, en et nl" do
    manifest = Partiduo::Modules[Sepa::CODE]
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        keys.each { |key| I18n.t(key).should_not contain("missing") }
      end
    end
    I18n.with_locale("fr") { I18n.t("sepa.menu.sepa").should eq("Paiements SEPA") }
  end

  it "est inactive tant que l'instance ne l'active pas, puis se montre au menu « Paiements SEPA »" do
    PartiduoUi::Reference.provision
    S.user("alice@example.com", "Alice")
    S.user("bruno@example.com", "Bruno")
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.batches(S.reader) }
    Api.tile(S.reader).should be_nil
    Api.pending_count(S.reader).should be_nil
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("sepa:batches")

    S.activate
    Partiduo::Modules.check!
    section = Partiduo::Api::Modules.menu(S.reader).find! { |item| item.code == "SEPA" }
    section.label_key.should eq("sepa.menu.sepa")
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should contain("sepa:batches")
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("sepa:batch_new")
    menu_routes(Partiduo::Api::Modules.menu(S.accountant)).should contain("sepa:settings")
  end

  it "range ses tables sous le préfixe sepa_ et refuse en base les valeurs hors domaine" do
    [Sepa::Setting, Sepa::Mandate, Sepa::Batch, Sepa::Item].map(&.db_table)
      .should eq(%w[sepa_setting sepa_mandate sepa_batch sepa_item])
    S.setup
    sql_error = ->(sql : String) do
      Marten::DB::Connection.default.open(&.exec(sql))
      nil
  rescue ex : PQ::PQError
    ex.message
    end
    sql_error.call("INSERT INTO sepa_setting (settlement_mode, batch_booking, created_at, updated_at) " \
                   "VALUES ('never', TRUE, now(), now())").to_s.should contain("sepa_setting_settlement_check")
    batch = S.batch
    sql_error.call("UPDATE sepa_batch SET status = 'approved' WHERE id = #{batch.id}").to_s.should contain("sepa_batch_file_check")
    sql_error.call("INSERT INTO sepa_item (batch_id, position, card_code, name, amount, settlement, created_at, updated_at) " \
                   "VALUES (#{batch.id}, 1, 'X', 'X', 0, 'none', now(), now())").to_s.should contain("sepa_item_amount_check")
    sql_error.call("INSERT INTO sepa_mandate (card_code, rum, signed_on, debtor_name, iban, created_at, updated_at) " \
                   "VALUES ('X', 'A//B', '2026-01-01', 'X', 'FR7630006000011234567890189', now(), now())")
      .to_s.should contain("sepa_mandate_rum_check")
  end
end
