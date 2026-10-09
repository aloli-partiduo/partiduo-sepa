# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Ce qui entoure la production d'un fichier : adresses des tiers relues
  # dans leurs fiches, contrôles du fichier produit (structure, puis XSD
  # officiel s'il est déposé, D-SEPA-012). Interne.
  module Producer
    # Adresse principale de chaque tiers du lot, par quick code ; relue avec
    # l'acteur système (le lot a déjà été contrôlé avec les droits de
    # l'acteur).
    def self.addresses(items : Array(Item)) : Hash(String, Partiduo::Api::Cards::AddressView)
      codes = items.map(&.card_code.to_s).uniq!
      codes.each_with_object({} of String => Partiduo::Api::Cards::AddressView) do |code, found|
        card = Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code)
        card.try(&.address).try { |address| found[code] = address }
      end
    end

    # Problèmes du fichier : contrôle structurel, et validation XSD quand le
    # schéma officiel est déposé.
    def self.problems(content : String, kind : String) : Array(String)
      problems = Structure.problems(content, kind)
      schema = kind == "debit" ? Api::DEBIT_SCHEMA : Api::TRANSFER_SCHEMA
      Schema.problems(content, schema).try { |found| problems.concat(found) }
      problems
    end
  end
end
