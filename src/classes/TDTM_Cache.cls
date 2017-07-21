public class TDTM_Cache implements Cache.CacheBuilder  {
    public Object doLoad(String str) {
        return [select Asynchronous__c, Class__c, Load_Order__c, Object__c, Active__c, Usernames_to_Exclude__c, 
                Trigger_Action__c from Trigger_Handler__c order by Load_Order__c];
    }
}