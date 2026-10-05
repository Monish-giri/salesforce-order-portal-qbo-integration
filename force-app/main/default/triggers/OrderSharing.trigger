trigger OrderSharing on Order (after insert) {
    if (Trigger.isAfter && Trigger.isInsert) {
        OrderSharingService.shareOrders(Trigger.new);
    }
}
