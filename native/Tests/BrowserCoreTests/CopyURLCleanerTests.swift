import Foundation
import Testing
@testable import BrowserCore

struct CopyURLCleanerTests {
    @Test(arguments: [
        ("https://news.test/story?utm_source=mail&utm_medium=email&utm_campaign=launch&utm_content=hero&utm_term=browser&id=42#read", "https://news.test/story?id=42#read"),
        ("https://shop.test/item?fbclid=synthetic&size=M&gclid=synthetic", "https://shop.test/item?size=M"),
        ("https://news.test/?UTM_Source=x&%75tm_medium=y&q=a%20b&q=c+d&empty=", "https://news.test/?q=a%20b&q=c+d&empty="),
        ("https://www.amazon.com/Book/dp/B012345678/ref=sr_1_1?tag=sample-20&linkCode=abc&linkId=123&ascsubtag=abc&camp=1&creative=2&creativeASIN=B012345678&th=1&psc=1", "https://www.amazon.com/Book/dp/B012345678?th=1&psc=1"),
        ("https://amazon.co.uk/gp/product/B012345678/ref_=abc?ref_=abc&ref=abc&pf_rd_p=x&pd_rd_w=y&language=en_GB", "https://amazon.co.uk/gp/product/B012345678?language=en_GB"),
        ("https://www.instagram.com/reel/ABC/?igsh=synthetic&igshid=synthetic&img_index=2", "https://www.instagram.com/reel/ABC/?img_index=2"),
        ("https://search.test/?q=swift&sort=date&page=2&tag=work&ref=docs&igsh=keep", "https://search.test/?q=swift&sort=date&page=2&tag=work&ref=docs&igsh=keep"),
        ("https://amazon.com.example.test/ref=keep?tag=work&pd_rd_w=keep", "https://amazon.com.example.test/ref=keep?tag=work&pd_rd_w=keep"),
        ("https://instagram.com.example.test/?igsh=keep", "https://instagram.com.example.test/?igsh=keep"),
        ("https://news.test/?return=https%3A%2F%2Fsite.test%2F%3Futm_source%3Dx#utm_source=keep", "https://news.test/?return=https%3A%2F%2Fsite.test%2F%3Futm_source%3Dx#utm_source=keep"),
        ("https://shop.test/?gclid=x", "https://shop.test/"),
        ("file:///tmp/ref=keep?utm_source=keep", "file:///tmp/ref=keep?utm_source=keep")
    ])
    func cleaning(pair: (String, String)) {
        let result = BrowserCopyURLCleaner.clean(URL(string: pair.0)!)
        #expect(result.absoluteString == pair.1)
        #expect(BrowserCopyURLCleaner.clean(result) == result)
    }
}
