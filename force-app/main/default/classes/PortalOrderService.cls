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
        @AuraEnabled public String paymentMethod;
        @AuraEnabled public String paymentStatus;
        @AuraEnabled public String invoiceStatus;
        @AuraEnabled public String qboInvoiceId;
        @AuraEnabled public String qboInvoiceNumber;
        @AuraEnabled public Date invoiceIssueDate;
        @AuraEnabled public Date invoiceDueDate;
        @AuraEnabled public List<B2BEarlyPaymentDiscountService.DiscountRule> discountSchedule = new List<B2BEarlyPaymentDiscountService.DiscountRule>();
        @AuraEnabled public B2BEarlyPaymentDiscountService.DiscountResult currentDiscount;
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
            SELECT Id, OrderNumber, Account.Name, Status, EffectiveDate, TotalAmount,
                   Payment_Method__c, Payment_Status__c, Invoice_Status__c,
                   QBO_Invoice_Id__c, QBO_Invoice_Number__c,
                   Invoice_Issue_Date__c, Invoice_Due_Date__c
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
        detail.paymentMethod = orderRecord.Payment_Method__c;
        detail.paymentStatus = orderRecord.Payment_Status__c;
        detail.invoiceStatus = orderRecord.Invoice_Status__c;
        detail.qboInvoiceId = orderRecord.QBO_Invoice_Id__c;
        detail.qboInvoiceNumber = orderRecord.QBO_Invoice_Number__c;
        detail.invoiceIssueDate = orderRecord.Invoice_Issue_Date__c;
        detail.invoiceDueDate = orderRecord.Invoice_Due_Date__c;

        if (orderRecord.Payment_Method__c == 'Invoice') {
            detail.discountSchedule = B2BEarlyPaymentDiscountService.getActiveSchedule();

            if (orderRecord.Invoice_Issue_Date__c != null &&
                orderRecord.Invoice_Due_Date__c != null &&
                orderRecord.Invoice_Balance__c != null) {
                detail.currentDiscount = B2BEarlyPaymentDiscountService.calculate(
                    orderRecord.Invoice_Issue_Date__c,
                    orderRecord.Invoice_Due_Date__c,
                    orderRecord.Invoice_Balance__c,
                    Date.today()
                );
            }
        }

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
