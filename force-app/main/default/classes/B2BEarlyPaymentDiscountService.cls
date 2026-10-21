public with sharing class B2BEarlyPaymentDiscountService {
    public class DiscountResult {
        @AuraEnabled public Boolean eligible { get; set; }
        @AuraEnabled public Decimal discountPercent { get; set; }
        @AuraEnabled public Decimal discountAmount { get; set; }
        @AuraEnabled public Decimal payableAmount { get; set; }
        @AuraEnabled public Integer paymentDay { get; set; }
        @AuraEnabled public String message { get; set; }

        public DiscountResult() {
            eligible = false;
            discountPercent = 0;
            discountAmount = 0;
            payableAmount = 0;
            paymentDay = null;
        }
    }

    public class DiscountRule {
        @AuraEnabled public Integer dayFrom { get; set; }
        @AuraEnabled public Integer dayTo { get; set; }
        @AuraEnabled public Decimal discountPercent { get; set; }
        @AuraEnabled public Integer priority { get; set; }

        public DiscountRule(Integer dayFrom, Integer dayTo, Decimal discountPercent, Integer priority) {
            this.dayFrom = dayFrom;
            this.dayTo = dayTo;
            this.discountPercent = discountPercent == null ? 0 : discountPercent;
            this.priority = priority;
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<DiscountRule> getActiveSchedule() {
        List<DiscountRule> schedule = new List<DiscountRule>();

        for (B2B_Early_Payment_Discount__mdt rule : [
            SELECT Day_From__c, Day_To__c, Discount_Percentage__c, Priority__c
            FROM B2B_Early_Payment_Discount__mdt
            WHERE Audience__c = 'Partner'
              AND Active__c = true
            ORDER BY Day_From__c ASC, Priority__c ASC
        ]) {
            schedule.add(new DiscountRule(
                rule.Day_From__c == null ? null : rule.Day_From__c.intValue(),
                rule.Day_To__c == null ? null : rule.Day_To__c.intValue(),
                rule.Discount_Percentage__c,
                rule.Priority__c == null ? null : rule.Priority__c.intValue()
            ));
        }

        return schedule;
    }

    public static DiscountResult calculate(Date invoiceDate, Date dueDate, Decimal invoiceBalance, Date paymentDate) {
        DiscountResult result = new DiscountResult();

        if (invoiceDate == null || dueDate == null || invoiceBalance == null || invoiceBalance <= 0 || paymentDate == null) {
            result.message = 'Discount cannot be calculated because invoice dates or balance are missing.';
            return result;
        }

        if (paymentDate > dueDate) {
            result.message = 'The invoice is past due and no early-payment discount applies.';
            result.payableAmount = invoiceBalance;
            return result;
        }

        Integer day = invoiceDate.daysBetween(paymentDate) + 1;
        if (day < 1) {
            result.message = 'Payment date cannot be before invoice issue date.';
            result.payableAmount = invoiceBalance;
            return result;
        }

        result.paymentDay = day;

        List<B2B_Early_Payment_Discount__mdt> rules = [
            SELECT Audience__c, Day_From__c, Day_To__c, Discount_Percentage__c, Active__c, Priority__c
            FROM B2B_Early_Payment_Discount__mdt
            WHERE Audience__c = 'Partner'
              AND Active__c = true
              AND Day_From__c <= :day
              AND Day_To__c >= :day
            ORDER BY Priority__c ASC
        ];

        if (rules.isEmpty()) {
            result.message = 'No early-payment discount applies for this payment date.';
            result.payableAmount = invoiceBalance;
            return result;
        }

        Decimal percent = rules[0].Discount_Percentage__c == null ? 0 : rules[0].Discount_Percentage__c;
        Decimal discountAmount = invoiceBalance * percent / 100;

        result.eligible = percent > 0;
        result.discountPercent = percent;
        result.discountAmount = discountAmount.setScale(2);
        result.payableAmount = (invoiceBalance - discountAmount).setScale(2);
        result.message = 'Early-payment discount applied.';
        return result;
    }
}
