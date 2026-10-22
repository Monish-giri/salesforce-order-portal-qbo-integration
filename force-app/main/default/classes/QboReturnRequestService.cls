public with sharing class QboReturnRequestService {
    public class ReturnRequestException extends Exception {}

    public static Id createReturnRequest(
        Id orderId,
        Map<Id, Decimal> requestedQuantities,
        String reason
    ) {
        return createReturnRequest(orderId, requestedQuantities, reason, 'Applied to Invoice');
    }

    public static Id createReturnRequest(
        Id orderId,
        Map<Id, Decimal> requestedQuantities,
        String reason,
        String resolutionType
    ) {
        if (orderId == null || requestedQuantities == null || requestedQuantities.isEmpty()) {
            throw new ReturnRequestException('Order and at least one return line are required.');
        }

        // Validate that the portal user can access the order before switching the
        // actual return-record DML to system mode. This preserves the portal's
        // record-level security boundary while allowing a partner to create a
        // return against an order that is legitimately shared with that partner.
        List<Order> visibleOrders = [
            SELECT Id
            FROM Order
            WHERE Id = :orderId
            WITH USER_MODE
            LIMIT 1
        ];
        if (visibleOrders.isEmpty()) {
            throw new ReturnRequestException('The selected order could not be found or is not available to you.');
        }

        Order order = [
            SELECT Id, AccountId, Placed_By_Account__c, QBO_Invoice_Id__c,
                   (SELECT Id, Quantity, UnitPrice, Returned_Quantity__c,
                           PricebookEntry.Product2.Name
                    FROM OrderItems ORDER BY CreatedDate ASC)
            FROM Order WHERE Id = :orderId WITH SYSTEM_MODE LIMIT 1
        ];

        if (String.isBlank(order.QBO_Invoice_Id__c)) {
            throw new ReturnRequestException('The Order does not have a QBO Invoice Id.');
        }

        if (String.isBlank(resolutionType)) resolutionType = 'Applied to Invoice';
        if (resolutionType != 'Applied to Invoice' &&
            resolutionType != 'Refunded' &&
            resolutionType != 'Customer Credit') {
            throw new ReturnRequestException('Invalid resolution type.');
        }

        Map<Id, OrderItem> items = new Map<Id, OrderItem>(order.OrderItems);
        List<Return_Request_Line__c> lines = new List<Return_Request_Line__c>();

        for (Id itemId : requestedQuantities.keySet()) {
            Decimal requested = requestedQuantities.get(itemId);
            if (requested == null || requested <= 0) {
                throw new ReturnRequestException('Return quantity must be greater than zero.');
            }

            OrderItem item = items.get(itemId);
            if (item == null) {
                throw new ReturnRequestException('Return line does not belong to the Order.');
            }

            Decimal alreadyReturned = item.Returned_Quantity__c == null ? 0 : item.Returned_Quantity__c;
            Decimal remaining = item.Quantity - alreadyReturned;
            if (requested > remaining) {
                throw new ReturnRequestException(
                    'Return quantity for ' + item.PricebookEntry.Product2.Name +
                    ' exceeds the remaining returnable quantity of ' + remaining + '.'
                );
            }

            Decimal unitPrice = item.UnitPrice == null ? 0 : item.UnitPrice;
            lines.add(new Return_Request_Line__c(
                Order_Item__c = item.Id,
                Quantity__c = requested,
                Unit_Price__c = unitPrice,
                Tax_Amount__c = 0
            ));
        }

        if (lines.isEmpty()) {
            throw new ReturnRequestException('At least one return line is required.');
        }

        Return_Request__c request = new Return_Request__c(
            Order__c = order.Id,
            Placed_By_Account__c = order.Placed_By_Account__c == null
                ? order.AccountId
                : order.Placed_By_Account__c,
            Reason__c = reason,
            Resolution_Type__c = resolutionType,
            Status__c = 'Requested',
            Current_Step__c = 'Pending'
        );

        // The order was already authorized with USER_MODE above. The return
        // record itself is an internal business record and must be created even
        // when the portal user's account does not have edit access to the
        // referenced customer Account record.
        insert as system request;

        for (Return_Request_Line__c line : lines) {
            line.Return_Request__c = request.Id;
        }
        insert as system lines;

        return request.Id;
    }

    public static void approveReturnRequest(Id returnRequestId) {
        if (returnRequestId == null) {
            throw new ReturnRequestException('Return Request Id is required.');
        }
        update new Return_Request__c(Id = returnRequestId, Status__c = 'Approved');
    }
}
