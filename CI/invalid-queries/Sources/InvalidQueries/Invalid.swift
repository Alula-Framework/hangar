import Foundation
import Hangar

// Queries Postgres would reject at runtime. Every one of these must be a
// *compile* error — that is the whole assertion. The script that builds this
// package fails if any of them compiles, and also fails if the error arrives
// without the message that tells the reader what to do instead.

@Entity("invalid_posts")
struct Widget {
    @ID var id: UUID
    var viewCount: Int
    var ownerID: UUID
}

// ERROR: aggregate functions are not allowed in WHERE
func aggregateInWhere() -> Query<Widget, Widget> {
    Widget.where { $0.viewCount.sum() > 5 }
}

// ERROR: window functions are not allowed in HAVING
func windowInHaving() -> Query<Widget, Widget> {
    Widget.all.groupBy { $0.ownerID }.having { $0.viewCount.sum().over() > 5 }
}

// ERROR: window functions are not allowed in WHERE
func windowInWhere() -> Query<Widget, Widget> {
    Widget.where { $0.viewCount.sum().over() > 5 }
}
