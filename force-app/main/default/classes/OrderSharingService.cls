public without sharing class OrderSharingService {

    private static final String CUSTOMER_PROFILE = 'Portal Customer';
    private static final String PARTNER_PROFILE = 'Portal Partner';

    public static void shareOrders(List<Order> orders) {
        if (orders == null || orders.isEmpty()) {
            return;
        }

        Set<Id> placedByAccountIds = new Set<Id>();
        for (Order orderRecord : orders) {
            if (orderRecord.Placed_By_Account__c != null) {
                placedByAccountIds.add(orderRecord.Placed_By_Account__c);
            }
        }

        if (placedByAccountIds.isEmpty()) {
            return;
        }

        Map<Id, List<Id>> accountToPortalUsers = new Map<Id, List<Id>>();
        for (User portalUser : [
            SELECT Id, Contact.AccountId, Profile.Name
            FROM User
            WHERE IsActive = true
            AND ContactId != null
            AND Contact.AccountId IN :placedByAccountIds
            AND Profile.Name IN :CUSTOMER_PROFILE, :PARTNER_PROFILE
        ]) {
            if (!accountToPortalUsers.containsKey(portalUser.Contact.AccountId)) {
                accountToPortalUsers.put(
                    portalUser.Contact.AccountId,
                    new List<Id>()
                );
            }
            accountToPortalUsers.get(portalUser.Contact.AccountId).add(portalUser.Id);
        }

        if (accountToPortalUsers.isEmpty()) {
            return;
        }

        Set<Id> orderIds = new Map<Id, Order>(orders).keySet();
        Set<String> existingShareKeys = new Set<String>();

        for (OrderShare existingShare : [
            SELECT OrderId, UserOrGroupId
            FROM OrderShare
            WHERE OrderId IN :orderIds
            AND RowCause = 'Manual'
        ]) {
            existingShareKeys.add(
                buildShareKey(existingShare.OrderId, existingShare.UserOrGroupId)
            );
        }

        List<OrderShare> sharesToInsert = new List<OrderShare>();

        for (Order orderRecord : orders) {
            if (orderRecord.Placed_By_Account__c == null) {
                continue;
            }

            List<Id> portalUserIds =
                accountToPortalUsers.get(orderRecord.Placed_By_Account__c);

            if (portalUserIds == null) {
                continue;
            }

            for (Id portalUserId : portalUserIds) {
                String shareKey = buildShareKey(orderRecord.Id, portalUserId);

                if (existingShareKeys.contains(shareKey)) {
                    continue;
                }

                sharesToInsert.add(new OrderShare(
                    OrderId = orderRecord.Id,
                    UserOrGroupId = portalUserId,
                    OrderAccessLevel = 'Read',
                    RowCause = Schema.OrderShare.RowCause.Manual
                ));

                existingShareKeys.add(shareKey);
            }
        }

        if (!sharesToInsert.isEmpty()) {
            Database.insert(sharesToInsert, false);
        }
    }

    private static String buildShareKey(Id orderId, Id userOrGroupId) {
        return String.valueOf(orderId) + ':' + String.valueOf(userOrGroupId);
    }
}
