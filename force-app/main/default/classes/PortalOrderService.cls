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
        @AuraEnabled public Decimal invoiceBalance;
        @AuraEnabled public Boolean canPay;
        @AuraEnabled public List<B2BEarlyPaymentDiscountService.DiscountRule> discountSchedule = new List<B2BEarlyPaymentDiscountService.DiscountRule>();
        @AuraEnabled public B2BEarlyPaymentDiscountService.DiscountResult currentDiscount;
        @AuraEnabled public List<OrderLine> lines = new List<OrderLine>();
    }

    /**
     * Returns the Accounts whose Orders the current portal user is allowed to see.
     *
     * Customer users see Orders for their own Contact.AccountId.
     * Partner users see Orders for customer Accounts linked to their partner
     * Account through Account.Partner_Account__c. This matches the existing
     * PartnerCustomerAccountSharingService relationship model.
     */
    private class PortalContext {
        Id accountId;
        Id contactId;
        Boolean isPartner;
        Set<Id> customerAccountIds = new Set<Id>();
    }

    private static PortalContext getPortalContext() {
        User currentUser = [
            SELECT Id, UserType, ContactId, Contact.AccountId
            FROM User WHERE Id = :UserInfo.getUserId() WITH USER_MODE LIMIT 1
        ];
        PortalContext context = new PortalContext();
        context.contactId = currentUser.ContactId;
        context.accountId = currentUser.Contact == null ? null : currentUser.Contact.AccountId;
        context.isPartner = currentUser.UserType == 'PowerPartner';
        if (context.isPartner && context.accountId != null) {
            for (Account customerAccount : [
                SELECT Id FROM Account WHERE Partner_Account__c = :context.accountId WITH USER_MODE
            ]) context.customerAccountIds.add(customerAccount.Id);
        } else if (context.accountId != null) {
            context.customerAccountIds.add(context.accountId);
        }
        return context;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean isCurrentUserPartner() {
        return getPortalContext().isPartner;
    }

    @AuraEnabled(cacheable=true)
    public static List<OrderSummary> getOrders(String viewMode) {
        PortalContext context = getPortalContext();
        List<Order> orders;
        if (context.accountId == null) return new List<OrderSummary>();

        if (context.isPartner && viewMode == 'customers') {
            if (context.contactId == null || context.customerAccountIds.isEmpty()) return new List<OrderSummary>();
            orders = [
                SELECT Id, OrderNumber, Account.Name, Status, EffectiveDate, TotalAmount, (SELECT Id FROM OrderItems)
                FROM Order
                WHERE AccountId IN :context.customerAccountIds
                  AND Placed_By_Account__c = :context.accountId
                  AND Placed_By_Contact__c = :context.contactId
                WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 50
            ];
        } else {
            orders = [
                SELECT Id, OrderNumber, Account.Name, Status, EffectiveDate, TotalAmount, (SELECT Id FROM OrderItems)
                FROM Order WHERE AccountId = :context.accountId
                WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 50
            ];
        }

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

    private static Order getOrderForSelectedView(Id orderId, PortalContext context, String viewMode) {
        if (context.accountId == null) return null;
        List<Order> matches;
        if (context.isPartner && viewMode == 'customers') {
            if (context.contactId == null || context.customerAccountIds.isEmpty()) return null;
            matches = [
                SELECT Id, OrderNumber, Account.Name, Status, EffectiveDate, TotalAmount,
                       Payment_Method__c, Payment_Status__c, Invoice_Status__c,
                       QBO_Invoice_Id__c, QBO_Invoice_Number__c, Invoice_Issue_Date__c,
                       Invoice_Due_Date__c, Invoice_Balance__c, Placed_By_Contact__c
                FROM Order
                WHERE Id = :orderId AND AccountId IN :context.customerAccountIds
                  AND Placed_By_Account__c = :context.accountId
                  AND Placed_By_Contact__c = :context.contactId
                WITH USER_MODE LIMIT 1
            ];
        } else {
            matches = [
                SELECT Id, OrderNumber, Account.Name, Status, EffectiveDate, TotalAmount,
                       Payment_Method__c, Payment_Status__c, Invoice_Status__c,
                       QBO_Invoice_Id__c, QBO_Invoice_Number__c, Invoice_Issue_Date__c,
                       Invoice_Due_Date__c, Invoice_Balance__c, Placed_By_Contact__c
                FROM Order WHERE Id = :orderId AND AccountId = :context.accountId
                WITH USER_MODE LIMIT 1
            ];
        }
        return matches.isEmpty() ? null : matches[0];
    }

    @AuraEnabled(cacheable=true)
    public static OrderDetail getOrderDetail(Id orderId, String viewMode) {
        if (orderId == null) {
            throw new AuraHandledException('Select an order to view its details.');
        }

        PortalContext context = getPortalContext();
        Order orderRecord = getOrderForSelectedView(orderId, context, viewMode);
        if (orderRecord == null) {
            throw new AuraHandledException('The selected order could not be found or you do not have access to it.');
        }

        Id currentContactId = context.contactId;

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
        detail.invoiceBalance = orderRecord.Invoice_Balance__c;

        // The order remains visible to linked users, but only the Contact who
        // placed the order is allowed to initiate its online payment.
        detail.canPay = currentContactId != null &&
            orderRecord.Placed_By_Contact__c != null &&
            orderRecord.Placed_By_Contact__c == currentContactId &&
            orderRecord.Payment_Status__c != 'Paid' &&
            orderRecord.Invoice_Status__c == 'Invoiced' &&
            orderRecord.Invoice_Balance__c != null &&
            orderRecord.Invoice_Balance__c > 0 &&
            orderRecord.Payment_Method__c != 'Cash on Delivery';

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

        List<OrderItem> items = [
            SELECT Id, Quantity, UnitPrice, TotalPrice, PricebookEntry.Product2.Name
            FROM OrderItem
            WHERE OrderId = :orderRecord.Id
            WITH USER_MODE
            ORDER BY CreatedDate
        ];

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
