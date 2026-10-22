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

    @AuraEnabled(cacheable=true)
    public static List<ReturnSummary> getReturns() {
        // Authorize the portal user's visibility through the Order first. Return
        // requests are created by system-mode DML, so they cannot be queried
        // directly with sharing and used as the authorization boundary.
        List<Order> visibleOrders = [
            SELECT Id
            FROM Order
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];

        if (visibleOrders.isEmpty()) {
            return new List<ReturnSummary>();
        }

        Set<Id> visibleOrderIds = new Set<Id>();
        for (Order orderRecord : visibleOrders) {
            visibleOrderIds.add(orderRecord.Id);
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
            results.add(summary);
        }

        return results;
    }
}
