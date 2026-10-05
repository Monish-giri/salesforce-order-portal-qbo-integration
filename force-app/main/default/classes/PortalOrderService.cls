public with sharing class PortalOrderService {
    public class OrderSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String accountName;
        @AuraEnabled public String status;
        @AuraEnabled public Date effectiveDate;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public Integer itemCount;
    }

    public class OrderLine {
        @AuraEnabled public Id id;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal totalPrice;
    }

    public class OrderDetail {
        @AuraEnabled public Id id;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String accountName;
        @AuraEnabled public String status;
        @AuraEnabled public Date effectiveDate;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public List<OrderLine> lines = new List<OrderLine>();
    }

    @AuraEnabled(cacheable=true)
    public static List<OrderSummary> getOrders() {
        List<Order> orders = [
            SELECT Id, OrderNumber, Account.Name, Status, EffectiveDate, TotalAmount,
                   (SELECT Id FROM OrderItems)
            FROM Order
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];

        List<OrderSummary> results = new List<OrderSummary>();
        for (Order orderRecord : orders) {
            OrderSummary summary = new OrderSummary();
            summary.id = orderRecord.Id;
            summary.orderNumber = orderRecord.OrderNumber;
            summary.accountName = orderRecord.Account.Name;
            summary.status = orderRecord.Status;
            summary.effectiveDate = orderRecord.EffectiveDate;
            summary.totalAmount = orderRecord.TotalAmount;
            summary.itemCount = orderRecord.OrderItems.size();
            results.add(summary);
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static OrderDetail getOrderDetail(Id orderId) {
        if (orderId == null) {
            throw new AuraHandledException('Select an order to view its details.');
        }

        List<Order> orders = [
            SELECT Id, OrderNumber, Account.Name, Status, EffectiveDate, TotalAmount
            FROM Order
            WHERE Id = :orderId
            WITH USER_MODE
            LIMIT 1
        ];

        if (orders.isEmpty()) {
            throw new AuraHandledException('The selected order could not be found.');
        }

        Order orderRecord = orders[0];

        List<OrderItem> items = [
            SELECT Id, Quantity, UnitPrice, TotalPrice, PricebookEntry.Product2.Name
            FROM OrderItem
            WHERE OrderId = :orderRecord.Id
            WITH USER_MODE
            ORDER BY CreatedDate
        ];

        OrderDetail detail = new OrderDetail();
        detail.id = orderRecord.Id;
        detail.orderNumber = orderRecord.OrderNumber;
        detail.accountName = orderRecord.Account.Name;
        detail.status = orderRecord.Status;
        detail.effectiveDate = orderRecord.EffectiveDate;
        detail.totalAmount = orderRecord.TotalAmount;

        for (OrderItem item : items) {
            OrderLine line = new OrderLine();
            line.id = item.Id;
            line.productName = item.PricebookEntry.Product2.Name;
            line.quantity = item.Quantity;
            line.unitPrice = item.UnitPrice;
            line.totalPrice = item.TotalPrice;
            detail.lines.add(line);
        }

        return detail;
    }
}
