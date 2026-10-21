public with sharing class B2BEarlyPaymentDiscountService {
    public class DiscountResult {
        @AuraEnabled public Decimal percent;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Integer dayNumber;
        @AuraEnabled public Boolean eligible;
        @AuraEnabled public String label;

        public DiscountResult() {
            percent = 0;
            amount = 0;
            dayNumber = 0;
            eligible = false;
            label = 'No early-payment discount';
        }
    }

    /**
     * Resolves the configured B2B discount for a payment date.
     * Day 1 is the invoice issue date. Payments after the due date receive 0%.
     */
    @AuraEnabled(cacheable=true)
    public static DiscountResult calculate(Date invoiceIssueDate, Date dueDate, Date paymentDate, Decimal invoiceAmount) {
        DiscountResult result = new DiscountResult();

        if (invoiceIssueDate == null || dueDate == null || paymentDate == null || invoiceAmount == null || invoiceAmount <= 0) {
            return result;
        }

        if (paymentDate > dueDate) {
            return result;
        }

        Integer dayNumber = invoiceIssueDate.daysBetween(paymentDate) + 1;
        result.dayNumber = dayNumber;

        if (dayNumber < 1) {
            return result;
        }

        List<B2B_Early_Payment_Discount__mdt> tiers = [
            SELECT Day_From__c, Day_To__c, Discount_Percent__c
            FROM B2B_Early_Payment_Discount__mdt
            WHERE Audience__c = 'Partner'
              AND Active__c = true
              AND Day_From__c <= :dayNumber
              AND Day_To__c >= :dayNumber
            ORDER BY Day_From__c DESC
            LIMIT 1
        ];

        if (tiers.isEmpty()) {
            return result;
        }

        B2B_Early_Payment_Discount__mdt tier = tiers[0];
        result.percent = tier.Discount_Percent__c == null ? 0 : tier.Discount_Percent__c;
        result.amount = (invoiceAmount * result.percent / 100).setScale(2);
        result.eligible = result.percent > 0;
        result.label = 'Pay by day ' + String.valueOf(tier.Day_To__c.intValue()) + ' for ' + String.valueOf(result.percent) + '% discount';
        return result;
    }
}
