namespace Aqueous.Bindings.AstalNotifd
{
    public enum AstalNotifdUrgency
    {
        Low = 0,
        Normal = 1,
        Critical = 2
    }
    public enum AstalNotifdClosedReason
    {
        Expired = 1,
        DismissedByUser = 2,
        Closed = 3,
        Undefined = 4
    }
    public enum AstalNotifdState
    {
        Draft,
        Sent,
        Received
    }
}
