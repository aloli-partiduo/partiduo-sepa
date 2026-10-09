# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Identifiants bancaires et références de paiement (D-SEPA-006) : IBAN
  # (ISO 13616, clé modulo 97 de l'ISO 7064), BIC (ISO 9362), identifiant
  # créancier SEPA (ICS, clé modulo 97 sans le code d'activité), référence
  # structurée du créancier (RF, ISO 11649) et communication structurée
  # belge (12 chiffres, clé modulo 97). Interne ; le contrat en expose les
  # contrôles (`Api.iban_valid?`…).
  module Codes
    # Longueur de l'IBAN des pays de l'espace SEPA (registre SWIFT de
    # l'ISO 13616) ; un pays absent n'est contrôlé que par la clé.
    IBAN_LENGTHS = {
      "AD" => 24, "AT" => 20, "BE" => 16, "BG" => 22, "CH" => 21, "CY" => 28, "CZ" => 24, "DE" => 22,
      "DK" => 18, "EE" => 20, "ES" => 24, "FI" => 18, "FR" => 27, "GB" => 22, "GI" => 23, "GR" => 27,
      "HR" => 21, "HU" => 28, "IE" => 22, "IS" => 26, "IT" => 27, "LI" => 21, "LT" => 20, "LU" => 20,
      "LV" => 21, "MC" => 27, "MT" => 31, "NL" => 18, "NO" => 15, "PL" => 28, "PT" => 25, "RO" => 24,
      "SE" => 24, "SI" => 19, "SK" => 24, "SM" => 27, "VA" => 22,
    }

    # Forme compacte : sans espaces, points, tirets ni barres, en majuscules
    # (`fr76 3000 …` → `FR763000…`).
    def self.compact(value : String) : String
      value.gsub(/[\s.\-\/]/, "").upcase
    end

    def self.valid_iban?(value : String) : Bool
      iban = compact(value)
      return false unless iban.matches?(/\A[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\z/)
      if length = IBAN_LENGTHS[iban[0, 2]]?
        return false unless iban.size == length
      end
      mod97(iban[4..] + iban[0, 4]) == 1
    end

    # Pays de l'IBAN (`FR`), ou chaîne vide.
    def self.iban_country(value : String) : String
      iban = compact(value)
      iban.size >= 2 ? iban[0, 2] : ""
    end

    # IBAN groupé par quatre pour l'affichage.
    def self.format_iban(value : String) : String
      compact(value).scan(/.{1,4}/).map(&.[0]).join(' ')
    end

    # IBAN masqué (liste des mandats) : pays, clé et quatre derniers
    # caractères, comme l'extension URSSAF (D-URS-003).
    def self.mask(value : String) : String
      iban = compact(value)
      return "****" if iban.size < 8
      "#{iban[0, 4]} **** **** #{iban[-4..]}"
    end

    # BIC : banque (4 lettres), pays (2 lettres), localité (2), agence
    # facultative (3).
    def self.valid_bic?(value : String) : Bool
      compact(value).matches?(/\A[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?\z/)
    end

    # Identifiant créancier SEPA (`FR12ZZZ123456`, `BE69ZZZ0123456789`) :
    # pays, clé, code d'activité (3 caractères libres), identifiant national ;
    # la clé se calcule sur l'identifiant national suivi du pays et de `00`.
    def self.valid_ics?(value : String) : Bool
      ics = compact(value)
      return false unless ics.matches?(/\A[A-Z]{2}[0-9]{2}[A-Z0-9]{3}[A-Z0-9]{1,28}\z/)
      check = 98 - mod97("#{ics[7..]}#{ics[0, 2]}00")
      check == ics[2, 2].to_i
    end

    # Référence structurée du créancier ISO 11649 (`RF18 5390 0754 7034`).
    def self.valid_rf?(value : String) : Bool
      reference = compact(value)
      return false unless reference.matches?(/\ARF[0-9]{2}[A-Z0-9]{1,21}\z/)
      mod97(reference[4..] + reference[0, 4]) == 1
    end

    # Communication structurée belge (`+++090/9337/55493+++`) : douze
    # chiffres, les deux derniers étant le reste modulo 97 des dix premiers
    # (97 pour un reste nul). Rend les douze chiffres, ou `nil`.
    def self.belgian_reference(value : String) : String?
      text = value.strip
      return unless text.matches?(/\A(\+\+\+|\*\*\*)?\s*\d{3}\s*\/?\s*\d{4}\s*\/?\s*\d{5}\s*(\+\+\+|\*\*\*)?\z/)
      digits = text.gsub(/\D/, "")
      return unless digits.size == 12
      rest = digits[0, 10].to_i64 % 97
      rest = 97_i64 if rest.zero?
      rest == digits[10, 2].to_i64 ? digits : nil
    end

    # Nature d'une communication : `rf` (ISO 11649), `bba` (belge
    # structurée) ou `text` (libre).
    def self.reference_kind(value : String) : String
      if valid_rf?(value)
        "rf"
      elsif belgian_reference(value)
        "bba"
      else
        "text"
      end
    end

    # Reste modulo 97 d'une chaîne alphanumérique (lettres : A = 10 … Z = 35),
    # calculé chiffre à chiffre.
    def self.mod97(text : String) : Int32
      text.each_char.reduce(0) do |rest, char|
        if char.ascii_number?
          (rest * 10 + char.to_i) % 97
        else
          (rest * 100 + (char.ord - 'A'.ord + 10)) % 97
        end
      end
    end
  end
end
