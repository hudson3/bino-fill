import Foundation

extension Vault {
    /// Made-up person for tests and the local practice site. The card number is the
    /// payment industry's published test number; nothing here belongs to anyone.
    public static var sample: Vault {
        var vault = Vault()
        vault.profile.title = "Mr"
        vault.profile.firstName = "Alex"
        vault.profile.middleName = "Jordan"
        vault.profile.lastName = "Rivera"
        vault.profile.dateOfBirth = "1990-03-14"
        vault.profile.gender = "Male"
        vault.profile.nationality = "United States"
        vault.profile.email = "alex.rivera@example.com"
        vault.profile.phone = "+1 512 555 0142"
        vault.profile.address.line1 = "200 Example Street"
        vault.profile.address.line2 = "Apt 4B"
        vault.profile.address.city = "Austin"
        vault.profile.address.state = "Texas"
        vault.profile.address.postalCode = "78701"
        vault.profile.address.country = "United States"
        vault.profile.passport.number = "X12345678"
        vault.profile.passport.issuingCountry = "United States"
        vault.profile.passport.issueDate = "2021-06-01"
        vault.profile.passport.expiryDate = "2031-05-31"
        vault.profile.knownTravelerNumber = "TT1234567"

        var loyalty = Loyalty()
        loyalty.program = "Practice Air SkyPoints"
        loyalty.number = "PA998877"
        vault.profile.loyalty = [loyalty]

        var card = Card()
        card.label = "Test Visa"
        card.cardholderName = "Alex J Rivera"
        card.number = "4242 4242 4242 4242"
        card.expMonth = "8"
        card.expYear = "2029"
        card.cvv = "123"
        card.isDefault = true
        vault.cards = [card]

        var login = Login()
        login.site = "localhost"
        login.username = "alex.rivera"
        login.password = "practice-only-password"
        vault.logins = [login]
        return vault
    }
}
