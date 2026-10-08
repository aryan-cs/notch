//
//  OTPDetectorTests.swift
//  boringNotchTests
//

import XCTest

@testable import boringNotch

final class OTPDetectorTests: XCTestCase {
    func testEmojiImmediatelyBeforeAndAfterDigits() {
        for text in ["Code 1234🔒", "🔒1234 code", "OTP 🔒1234🔒"] {
            XCTAssertEqual(OTPDetector.detect(in: text), "1234", text)
        }
    }

    func testSupplementaryAndCombinedCharacterBoundaries() {
        // Musical symbols, variation selectors, skin tones, and ZWJ sequences
        // each exercise boundaries beyond a single UTF-16 code unit.
        for boundary in ["𝄞", "☎️", "👍🏽", "👩‍💻", "🔒\u{0301}"] {
            for text in ["OTP \(boundary)1234", "OTP 1234\(boundary)"] {
                XCTAssertEqual(OTPDetector.detect(in: text), "1234", text)
            }
        }
    }

    func testBeginningAndEndOfString() {
        XCTAssertEqual(OTPDetector.detect(in: "1234 is your code"), "1234")
        XCTAssertEqual(OTPDetector.detect(in: "Your code is 1234"), "1234")
        XCTAssertNil(OTPDetector.detect(in: "1234"))
        XCTAssertNil(OTPDetector.detect(in: ""))
    }

    func testOrdinaryAndSplitNumericCodes() {
        for (text, expected) in [
            ("Your code is 482910", "482910"),
            ("OTP 123-456", "123456"),
            ("OTP 123 456", "123456"),
            ("OTP 🔒123-456🔒", "123456"),
            ("Code 12345678", "12345678")
        ] {
            XCTAssertEqual(OTPDetector.detect(in: text), expected, text)
        }
    }

    func testCurrencyPercentageAndClockExclusions() {
        for currency in ["$", "€", "£", "¥", "₹"] {
            let text = "OTP delivery fee \(currency)1234🔒"
            XCTAssertNil(OTPDetector.detect(in: text), text)
        }
        for text in [
            "Code 🔒1234%",
            "Code 1234%\u{FE0F}",
            "Code 🔒1234:56",
            "Code 1234:\u{FE0F}56",
            "Code 12:3456🔒",
            "OTP fee 1234.50",
            "Code 123456789",
            "Call me at 9876543210",
            "Invoice 48293021"
        ] {
            XCTAssertNil(OTPDetector.detect(in: text), text)
        }
        XCTAssertEqual(OTPDetector.detect(in: "OTP fee $1234, use 5678"), "5678")
    }

    func testAlphanumericCodesRequireStrongContext() {
        XCTAssertEqual(OTPDetector.detect(in: "Verification code R7K9P2"), "R7K9P2")
        XCTAssertEqual(OTPDetector.detect(in: "OTP 🔒R7K9P2🔒"), "R7K9P2")
        for text in ["Promo code SAVE20", "Code R7K9P2", "OTP r7k9p2", "OTP ABCDEF"] {
            XCTAssertNil(OTPDetector.detect(in: text), text)
        }
    }

    func testRealWorldMessages() {
        let codes: [(String, String)] = [
            ("Your WhatsApp code: 123-456. Don't share this with anyone.", "123456"),
            ("G-593821 is your Google verification code.", "593821"),
            ("Your Instagram code is 482910. Learn more.", "482910"),
            ("Use 7482 as your verification code. Expires in 10 minutes.", "7482"),
            ("123456 is your Facebook confirmation code", "123456"),
            ("<#> Your ABC App code is 384950 #hash", "384950"),
            ("Your OTP for a transaction of INR 500.00 is 837201. Valid for 5 mins.", "837201"),
            ("Your Amazon OTP is: 4821", "4821"),
            ("Your Steam Guard verification code: R7K9P2", "R7K9P2")
        ]
        for (text, expected) in codes {
            XCTAssertEqual(OTPDetector.detect(in: text), expected, text)
        }
        for text in [
            "Hey, call me at 9876543210 when you're free",
            "Meeting at 3:30 today, don't forget code review at 4",
            "Your invoice #48293021 total is due",
            "Ref: 293847, please quote when calling about your 2023 order",
            "Get 20% off with code SAVE20 at checkout",
            "The OTP delivery fee is $5000 this month"
        ] {
            XCTAssertNil(OTPDetector.detect(in: text), text)
        }
    }
}
