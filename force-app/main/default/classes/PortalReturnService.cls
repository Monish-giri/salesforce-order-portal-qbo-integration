public with sharing class PortalReturnService {
    public class ReturnSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String returnNumber;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String status;
        @AuraEnabled public String currentStep;
        @AuraEnabled public String reason;
        @AuraEnabled public String resolutionType;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public Date createdDate;
        @AuraEnabled public String creditMemoId;
        @AuraEnabled public String paymentId;
        @AuraEnabled public String refundId;
    }

    public class ReturnLine {
        @AuraEnabled public Id id;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal lineAmount;
    }

    public class ReturnDetail {
        @AuraEnabled public Id id;
        @AuraEnabled public String returnNumber;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String status;
        @AuraEnabled public String currentStep;
        @AuraEnabled public String reason;
        @AuraEnabled public String resolutionType;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public Date createdDate;
        @AuraEnabled public String creditMemoId;
        @AuraEnabled public String paymentId;
        @AuraEnabled public String refundId;
        @AuraEnabled public List<ReturnLine> lines = new List<ReturnLine>();
    }

    @AuraEnabled(cacheable=true)
    public static List<ReturnSummary> getReturns() {
        Set<Id> visibleOrderIds = getVisibleOrderIds();
        if (visibleOrderIds.isEmpty()) {
            return new List<ReturnSummary>();
        }

        List<Return_Request__c> requests = [
            SELECT Id, Name, Order__c, Order__r.OrderNumber,
                   Status__c, Current_Step__c, Reason__c, Resolution_Type__c,
                   QBO_CreditMemo_Id__c, QBO_Payment_Id__c, QBO_Refund_Id__c,
                   CreatedDate,
                   (SELECT Line_Amount__c FROM Return_Request_Lines__r)
            FROM Return_Request__c
            WHERE Order__c IN :visibleOrderIds
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 100
        ];

        List<ReturnSummary> results = new List<ReturnSummary>();
        for (Return_Request__c request : requests) {
            results.add(toSummary(request));
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static ReturnDetail getReturnDetail(Id returnId) {
        if (returnId == null) {
            throw new AuraHandledException('Select a return request to view its details.');
        }

        Set<Id> visibleOrderIds = getVisibleOrderIds();
        if (visibleOrderIds.isEmpty()) {
            throw new AuraHandledException('The selected return could not be found.');
        }

        List<Return_Request__c> requests = [
            SELECT Id, Name, Order__c, Order__r.OrderNumber,
                   Status__c, Current_Step__c, Reason__c, Resolution_Type__c,
                   QBO_CreditMemo_Id__c, QBO_Payment_Id__c, QBO_Refund_Id__c,
                   CreatedDate,
                   (SELECT Id, Quantity__c, Unit_Price__c, Line_Amount__c,
                           Order_Item__c, Order_Item__r.PricebookEntry.Product2.Name
                    FROM Return_Request_Lines__r
                    ORDER BY CreatedDate)
            FROM Return_Request__c
            WHERE Id = :returnId
              AND Order__c IN :visibleOrderIds
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (requests.isEmpty()) {
            throw new AuraHandledException('The selected return could not be found.');
        }

        Return_Request__c request = requests[0];
        ReturnDetail detail = new ReturnDetail();
        detail.id = request.Id;
        detail.returnNumber = request.Name;
        detail.orderNumber = request.Order__r.OrderNumber;
        detail.status = request.Status__c;
        detail.currentStep = request.Current_Step__c;
        detail.reason = request.Reason__c;
        detail.resolutionType = request.Resolution_Type__c;
        detail.createdDate = request.CreatedDate.date();
        detail.creditMemoId = request.QBO_CreditMemo_Id__c;
        detail.paymentId = request.QBO_Payment_Id__c;
        detail.refundId = request.QBO_Refund_Id__c;

        Decimal total = 0;
        for (Return_Request_Line__c line : request.Return_Request_Lines__r) {
            ReturnLine returnLine = new ReturnLine();
            returnLine.id = line.Id;
            returnLine.productName = line.Order_Item__r != null && line.Order_Item__r.PricebookEntry != null
                ? line.Order_Item__r.PricebookEntry.Product2.Name
                : 'Product';
            returnLine.quantity = line.Quantity__c;
            returnLine.unitPrice = line.Unit_Price__c;
            returnLine.lineAmount = line.Line_Amount__c == null ? 0 : line.Line_Amount__c;
            total += returnLine.lineAmount;
            detail.lines.add(returnLine);
        }
        detail.totalAmount = total;

        return detail;
    }

    private static Set<Id> getVisibleOrderIds() {
        List<Order> visibleOrders = [
            SELECT Id
            FROM Order
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];

        Set<Id> visibleOrderIds = new Set<Id>();
        for (Order orderRecord : visibleOrders) {
            visibleOrderIds.add(orderRecord.Id);
        }
        return visibleOrderIds;
    }

    private static ReturnSummary toSummary(Return_Request__c request) {
        ReturnSummary summary = new ReturnSummary();
        summary.id = request.Id;
        summary.returnNumber = request.Name;
        summary.orderNumber = request.Order__r.OrderNumber;
        summary.status = request.Status__c;
        summary.currentStep = request.Current_Step__c;
        summary.reason = request.Reason__c;
        summary.resolutionType = request.Resolution_Type__c;
        summary.createdDate = request.CreatedDate.date();
        summary.creditMemoId = request.QBO_CreditMemo_Id__c;
        summary.paymentId = request.QBO_Payment_Id__c;
        summary.refundId = request.QBO_Refund_Id__c;

        Decimal total = 0;
        for (Return_Request_Line__c line : request.Return_Request_Lines__r) {
            total += line.Line_Amount__c == null ? 0 : line.Line_Amount__c;
        }
        summary.totalAmount = total;
        return summary;
    }
}
