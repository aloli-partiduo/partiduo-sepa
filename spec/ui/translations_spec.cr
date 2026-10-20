# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions des écrans de l'extension (ADR-005 D7) : chaque route de
# `/ext/SEPA/` servie en `GET` (liste tirée du routeur de Marten), obtenue
# en fr, en et nl par un administrateur, sur un lot de virements en
# préparation, un lot de prélèvements approuvé et deux mandats (l'un
# utilisé). Contrôle de l'interface (`PartiduoUi::Translations`) : ni
# marqueur de traduction absente, ni clé brute, ni interpolation non
# résolue, et toute route atteinte par les liens des pages.

private alias S = Sepa::SpecSupport
private alias Api = Sepa::Api

describe "Traductions des écrans SEPA (fr, en, nl)" do
  it "rend chaque écran dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    browser = PartiduoUi::Books.admin
    S.user("bruno@example.com", "Bruno")
    S.bank_iban(S::BANK_IBAN, S::BANK_BIC)
    S.activate
    S.supplier("Fournitures Alpha", "ALPHA", city: "Lyon")
    S.purchase("ALPHA", "100", "2026-09-10")
    transfers = S.batch
    Api.add_open_items(S.preparer, transfers.id, Api.candidates(S.preparer, transfers.id).map(&.line_id)).value!
    # Écriture ouverte restée hors du lot : formulaire d'ajout.
    S.purchase("ALPHA", "40", "2026-09-12")
    S.company(creditor_identifier: "fr72 zzz 123456")
    S.customer("Atelier Morel", "MOREL")
    S.mandate("MOREL")
    S.customer("Menuiserie Leroux", "LEROUX")
    S.mandate("LEROUX", rum: "LEROUX-2026-01")
    S.sale("MOREL", "80", "2026-09-21")
    debits = S.batch("debit", "2026-10-12", label: "Prélèvements")
    Api.add_open_items(S.preparer, debits.id, Api.candidates(S.preparer, debits.id).map(&.line_id)).value!
    Api.prepare(S.preparer, debits.id).value!
    Api.approve(S.accountant, debits.id).value!

    explorer = PartiduoUi::Translations::Explorer.new(&.name.starts_with?("sepa:"))
    # Routes que les écrans n'appellent qu'en POST (leur GET renvoie au
    # lot) : approbation (par l'écran des approbations du cœur), règlements.
    seeds = %w[approve settle].map { |command| "/ext/SEPA/batches/#{debits.id}/#{command}" }
    explorer.crawl(browser, "SEPA", seeds)
    puts "\nTraductions de SEPA : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end
