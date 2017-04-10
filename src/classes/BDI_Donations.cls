/*
    Copyright (c) 2017 Salesforce.org
    All rights reserved.
    
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:
    
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Salesforce.org nor the names of
      its contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.
 
    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE 
    COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; 
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
    POSSIBILITY OF SUCH DAMAGE.
*/
/**
* @author Salesforce.org
* @date 2017
* @group Batch Data Import
* @group-content ../../ApexDocContent/BatchDataImport.htm
* @description Helper class for the Batch Data Importer, dealing with Donations, ie, Opps and Payments
*
*/
public class BDI_Donations {

    /*******************************************************************************************************
    * @description constructor for the BDI Donations helper
    * @param bdi The Batch Data Import object the helper should use
    * @return void
    */ 
    public BDI_Donations(BDI_DataImport_BATCH bdi) {
        this.bdi = bdi;
    }

    /*******************************************************************************************************
    * @description The Batch Data Import object the helper should use
    */ 
    BDI_DataImport_BATCH bdi { get; set; }
    
    /*******************************************************************************************************
    * @description map to track the Opportunity created/matched for each DI record
    */ 
    private map<Id, Opportunity> mapDIIdToOpp = new map<Id, Opportunity>();

    /*******************************************************************************************************
    * @description map to track the Payment created/matched for each DI record
    */ 
    private map<Id, npe01__OppPayment__c> mapDIIdPmt = new map<Id, npe01__OppPayment__c>();
    
    /*******************************************************************************************************
    * @description provides a valid Close Won Opportunity Stage
    */
    private static string defaultClosedWonStage {
        get {   
            if (defaultClosedWonStage == null){
                List<OpportunityStage> listStg = [select masterlabel from opportunitystage where isActive = true and iswon = true];
                if (listStg.size() > 0) {
                    defaultClosedWonStage = listStg[0].masterlabel;
                } else {
                    defaultClosedWonStage = '';
                }
            }
            return defaultClosedWonStage;
        }
        set;
    }

    /*******************************************************************************************************
    * @description the class object that supports the BDI_IMatching interface
    */
    private static BDI_IMatching iMatching {
        get {
            if (iMatching == null) {
                string strClass = null; // UNDONE: setting or batch this is stored in? hns.Implementing_Class__c;
                if (strClass == null || strClass == '') {
                    strClass = 'BDI_Donations.BDIMatchingDonations';
                }
                Type classType = Type.forName(strClass);
                if (classType != null) {
                    Object classInstance = classType.newInstance();
                    if (classInstance instanceof BDI_IMatching) {
                        iMatching = (BDI_IMatching)classInstance;
                    }
                }
            }
            return iMatching;
        }
        set;
    }

    /*******************************************************************************************************
    * @description Imports the appropriate Donations into NPSP, following matching rules and criteria
    * to potentially match existing Opportunities or Payments.
    * @return void
    */ 
    public void importDonations() {
    
        // get the fields we will auto-copy
        map<string, string> mapDIFieldToOppField = 
            BDI_DataImport_BATCH.mapFieldsForDIObject('Opportunity', 'Opportunity', BDI_DataImport_BATCH.listStrDataImportFields);
        list<Opportunity> listOppInsert = new list<Opportunity>();
        list<Opportunity> listOppUpdate = new list<Opportunity>();
        list<DataImport__c> listDIInsert = new list<DataImport__c>();
        list<DataImport__c> listDIUpdate = new list<DataImport__c>();
        
        // get the list of DI records that have donations to process
        list<DataImport__c> listDIDonations = validateDonationsToProcess();
        
        // call the extension to match against existing donations
        mapDIIdToOpp = iMatching.matchDonations(bdi, listDIDonations);
        
        // now go thru the new & existing donations and update them
        for (DataImport__c di : listDIDonations) {
            Opportunity opp = mapDIIdToOpp.get(di.Id);
            string strOppName;
            
            // if there is no opp matched, create one for it
            boolean isNew = opp == null;
            if (isNew) {
                opp = new Opportunity();
                mapDIIdToOpp.put(di.Id, opp);
                if (di.Donation_Donor__c == 'Account1') {
                    Account acc = bdi.AccountFromDi(di, 1);
                    opp.accountId = acc.Id;    
                    strOppName = acc.Name;            
                } else { // we can assume it's for Contact1
                    Contact con = bdi.ContactFromDi(di, 1);
                    opp.npe01__Contact_Id_for_Role__c = con.Id;
                    opp.Primary_Contact__c = con.Id;
                    opp.Primary_Contact_Campaign_Member_Status__c = di.Campaign_Member_Status__c;
                    opp.AccountId = con.AccountId;
                    strOppName = con.Firstname + ' ' + con.Lastname;
                }
            }
            
            if (di.Donation_Record_Type_Name__c != null) {
                Id idRt = UTIL_RecordTypes.GetRecordTypeId(Opportunity.sObjectType, di.Donation_Record_Type_Name__c);
                if (idRt == null) {
                    bdi.LogBDIError(di, label.bdiErrorInvalidOppRTName, 'DonationImportStatus__c');
                    continue;
                }
                opp.RecordTypeId = idRt;
                strOppName += ' ' + di.Donation_Record_Type_Name__c;
            } else {
                strOppName += ' ' + label.bdiDonation;
            }
            
            if (di.Donation_Campaign_Name__c != null) {
                Id idCmp = bdi.mapStrNameToCampaignId.get(di.Donation_Campaign_Name__c);
                if (idCmp == null) {
                    bdi.LogBDIError(di, label.bdiErrorInvalidCampaignName, 'DonationImportStatus__c');
                    continue;
                }
                opp.CampaignId = idCmp;
            }
            
            if (di.Donation_Date__c == null) {
                if (isNew) {
                    di.Donation_Date__c = system.today();
                } else {
                    di.Donation_Date__c = opp.CloseDate;
                }
            }
            
            if (di.Donation_Name__c == null) {
                if (isNew) {
                    di.Donation_Name__c = strOppName + ' ' + di.Donation_Date__c.format();
                } else {
                    di.Donation_Name__c = opp.Name;
                }
            } 
                
            if (di.Donation_Stage__c == null && defaultClosedWonStage != '') {
                di.Donation_Stage__c = defaultClosedWonStage;
            }
            // now copy over all the data to the Opp
            for (string strDIField : mapDIFieldToOppField.keySet()) {
                BDI_DataImport_BATCH.isCopiedDIField(di, strDIField, opp, mapDIFieldToOppField);
            }

            if (isNew) {
                listOppInsert.add(opp);
                listDIInsert.add(di);
            } else {
                listOppUpdate.add(opp);
                listDIUpdate.add(di);
            }  
            if (Test.isRunningTest() && opp.Name != null && opp.Name.startsWith('FailTest'))
                opp.Name = null;
        }
        
        // insert our new Opps
        list<Database.SaveResult> listSR = database.insert(listOppInsert, false);
        for (integer i = 0; i < listSR.size(); i++) {
            Database.SaveResult sr = listSR[i];
            if (!sr.isSuccess()) {
                bdi.LogBDIError(listDIInsert[i], sr.getErrors()[0].getMessage(), 'DonationImportStatus__c');
            } else {
                listDIInsert[i].DonationImported__c = listOppInsert[i].Id;
                listDIInsert[i].DonationImportStatus__c = label.bdiCreated;
            }
        }
        
        // update our matched Opps
        listSR = database.update(listOppUpdate, false);
        for (integer i = 0; i < listSR.size(); i++) {
            Database.SaveResult sr = listSR[i];
            if (!sr.isSuccess()) {
                bdi.LogBDIError(listDIUpdate[i], sr.getErrors()[0].getMessage(), 'DonationImportStatus__c');
            }
        }

        // now deal with any payment child records
        updatePayments();      
    }

    /*******************************************************************************************************
    * @description validate bdi records for donations and return those to process
    * @return list<DataImport__c> The list of BDI records that have donations to process
    */ 
    public list<DataImport__c> validateDonationsToProcess() {
        list<DataImport__c> listDIDonations = new list<DataImport__c>();
        for (DataImport__c di : bdi.listDI) {
            // skip di's that already have an error
            if (di.Status__c == label.bdiFailed)
               continue;
            if (di.Donation_Donor__c == 'Contact1' || (di.Donation_Donor__c == null && di.Donation_Amount__c != null)) {
                di.Donation_Donor__c = 'Contact1';
                Contact con = bdi.ContactFromDi(di, 1);
                if (con == null) {
                    bdi.LogBDIError(di, label.bdiErrorInvalidDonor, 'DonationImportStatus__c');
                    continue;
                }
            } else if (di.Donation_Donor__c == 'Account1') {
                Account acc = bdi.AccountFromDi(di, 1);
                if (acc == null) {
                    bdi.LogBDIError(di, label.bdiErrorInvalidDonor, 'DonationImportStatus__c');
                    continue;
                }
            } else if (di.Donation_Donor__c != null) {
                bdi.LogBDIError(di, label.bdiErrorInvalidDonor, 'DonationImportStatus__c');
                continue;
            } else {
                // this DI record does not have a donation!
                continue;
            }
            // add the donation to our list
            listDIDonations.add(di);
        }
        return listDIDonations;
    }

    /*******************************************************************************************************
    * @description Updates any fields on payment objects created for the Data Import opportunities.
    * @return void
    */ 
    public void updatePayments() {

        // need to find payment records, to add any additional info.
        map<Id, npe01__OppPayment__c> mapOppIdToPayment = new map<Id, npe01__OppPayment__c>();
        for (npe01__OppPayment__c pmt : [select Id, npe01__Opportunity__c from npe01__OppPayment__c where npe01__Opportunity__c in :mapDIIdToOpp.values()]) {
            mapOppIdToPayment.put(pmt.npe01__Opportunity__c, pmt);
        }

        // get the payment fields we will auto-copy
        map<string, string> mapDIFieldToPmtField = 
            BDI_DataImport_BATCH.mapFieldsForDIObject('Payment', 'npe01__OppPayment__c', BDI_DataImport_BATCH.listStrDataImportFields);
        list<npe01__OppPayment__c> listPmtUpsert = new list<npe01__OppPayment__c>();
        list<DataImport__c> listDIUpsert = new list<DataImport__c>();

        // update payments
        for (DataImport__c di: bdi.listDI) {
            // skip di's that already have an error
            if (di.Status__c == label.bdiFailed)
               continue;            
            if (di.DonationImported__c != null) {
                npe01__OppPayment__c pmt = mapOppIdToPayment.get(di.DonationImported__c);
                if (pmt != null) {
                    integer cPropSet = 0;
                    for (string strDIField : mapDIFieldToPmtField.keySet()) {
                        if (BDI_DataImport_BATCH.isCopiedDIField(di, strDIField, pmt, mapDIFieldToPmtField)) {
                            cPropSet++;
                        }
                    }                    
                    if (cPropSet > 0) {
                        mapDIIdPmt.put(di.Id, pmt);
                        listPmtUpsert.add(pmt);
                        listDIUpsert.add(di);
                    }
                }
            }
        }
        
        //upsert mapDIIdPmt.values();
        list<Database.UpsertResult> listUR = database.upsert(listPmtUpsert, false);
        for (integer i = 0; i < listUR.size(); i++) {
            Database.UpsertResult ur = listUR[i];
            if (!ur.isSuccess()) {
                bdi.LogBDIError(listDIUpsert[i], ur.getErrors()[0].getMessage(), null);
            }
        }
        
    }
    
    /*******************************************************************************************************
    * @description Provides a default implementation of the BDI_IMatching interface, which supports matching
    * imported Donations with their appropriate Opportunity and Payment.
    */ 
    public class BDIMatchingDonations implements BDI_IMatching {
        
        private map<String, String> mapDIFieldToOppField = new map<String, String> {
            UTIL_Namespace.StrTokenNSPrefix('Donation_Amount__c') => 'Amount',
            UTIL_Namespace.StrTokenNSPrefix('Donation_Date__c') => 'CloseDate',
            UTIL_Namespace.StrTokenNSPrefix('Donation_Record_Type_Name__c') => 'RecordTypeId',
            UTIL_Namespace.StrTokenNSPrefix('Donation_Type__c') => 'Type',
            UTIL_Namespace.StrTokenNSPrefix('Donation_Campaign_Name__c') => 'Campaign'
        };
    
        /*******************************************************************************************************
        * @description For each of the provided Data Import records, look their existing Opportunity and Payment 
        * to update, storing the lookup and status back in the DI record.
        * This is the default implementation which will follow matching rules and criteria specified in settings.
        * @param listDI The list of Data Import records with donations
        * @return map<Id, Opportunity> a map of Data Import record Id's to their matched Opportunity
        */ 
        public map<Id, Opportunity> matchDonations(BDI_DataImport_BATCH bdi, list<DataImport__c> listDI) {

            map<Id, Opportunity> mapDIIdToOpp = new map<Id, Opportunity>();
            
            // collect all the contacts and accounts who have donations to import
            set<Id> setConId = new set<Id>();
            set<Id> setAccId = new set<Id>();
            set<Id> setOppId = new set<Id>();
            for (DataImport__c di : listDI) {
                // handle already been given the match!
                if (di.DonationImported__c != null) {
                    setOppId.add(di.DonationImported__c);
                } else if (di.Donation_Donor__c == 'Contact1') {
                    Contact con = bdi.ContactFromDi(di, 1);
                    setConId.add(con.Id);                                
                } else if (di.Donation_Donor__c == 'Account1') {
                    Account acc = bdi.AccountFromDi(di, 1);
                    setAccId.add(acc.Id);
                }
            }
            
            // if no donations to import, we can bail out
            if (setOppId.size() == 0 && setAccId.size() == 0 && setConId.size() == 0) {
                return mapDIIdToOpp;
            }
            
            // get our fields for the matching rule
            string strRules = bdi.diSettings.Donation_Matching_Rule__c;
            list<String> listMatchFields;
            if (strRules != null) {
                listMatchFields = strRules.split(',');
            } else {
                listMatchFields = new list<String>{
                    UTIL_Namespace.StrTokenNSPrefix('Donation_Amount__c'),
                    UTIL_Namespace.StrTokenNSPrefix('Donation_Date__c')
                };
            }
            
            // the set of fields for our soql
            set<String> setFields = new set<String>();
            setFields.add('Id');
            setFields.add('Name');
            setFields.add('Amount');
            setFields.add('AccountId');
            setFields.add(UTIL_Namespace.StrTokenNSPrefix('Primary_Contact__c'));
            setFields.add('CloseDate');
            
            // add the match fields
            for (String strField : listMatchFields) {
                String strOppField = mapDIFieldToOppField.get(strField);
                if (strOppField != null) {
                    setFields.add(strOppField);
                }
            }
            
            // now query for all Open Opportunities from these Contacts or Accounts
            integer cFilter = 0;
            string strSoql = 'select ' + string.join(new list<String>(setFields), ',');
            strSoql += ' from Opportunity';
            strSoql += ' where IsClosed = false and (';
            if (setOppId.size() > 0) {
                strSoql += ' Id in :setOppId ';
                cFilter++;
            }
            if (setAccId.size() > 0) {
                if (cFilter > 0) {
                    strSoql += ' or ';
                }
                strSoql += ' AccountId in :setAccId ';
                cFilter++;
            }
            if (setConId.size() > 0) {
                if (cFilter > 0) {
                    strSoql += ' or ';
                }
                strSoql += ' ' + UTIL_Namespace.StrTokenNSPrefix('Primary_Contact__c') + ' in :setConId ';
            }
            strSoql += ') order by CloseDate ASC';
            list<Opportunity> listOpp = database.query(strSoql);
            
            // put each contact's and account's opps in their own list
            map<Id, list<Opportunity>> mapConAccIdToOpps = new map<Id, list<Opportunity>>();
            for (Opportunity opp : listOpp) {
                ID id;
                if (opp.Primary_Contact__c != null) {
                    id = opp.Primary_Contact__c;
                } else {
                    id = opp.AccountId;
                }
                list<Opportunity> listCAOpps = mapConAccIdToOpps.get(id);
                if (listCAOpps == null) {
                    listCAOpps = new list<Opportunity>();
                    mapConAccIdToOpps.put(id, listCAOpps);
                }
                listCAOpps.add(opp);
            }
            
            // now look for the matching Opp for each donation
            for (DataImport__c di : listDI) {
                ID id;
                if (di.Donation_Donor__c == 'Account1') {
                    id = bdi.AccountFromDi(di, 1).Id;
                } else { // can assume Contact1
                    id = bdi.ContactFromDi(di, 1).Id;
                }
                list<Opportunity> listCAOpps = mapConAccIdToOpps.get(id);
                Opportunity oppBest;
                if (listCAOpps != null) {
                    for (integer i = 0; i < listCAOpps.size(); i++) {
                        Opportunity opp = listCAOpps[i];
                        // always match to an Opp we were given the Id to!
                        if (di.DonationImported__c == opp.Id) {
                            oppBest = opp;
                            break;
                        }
                        if (di.DonationImported__c == null) {
                            // try match against all specified fields
                            boolean isAllMatch = true;
                            for (String strDIField : listMatchFields) {
                                //system.debug('****DJH strDIField: ' + strDIField + ' di: ' + di.get(strDIField) + ' map: ' + mapDIFieldToOppField.get(strDIField) + ' opp: ' + opp.get(mapDIFieldToOppField.get(strDIField)));
                                Object val = di.get(strDIField);
                                if (strDIField == UTIL_Namespace.StrTokenNSPrefix('Donation_Record_Type_Name__c')) {
                                    val = UTIL_RecordTypes.getRecordTypeId(Opportunity.sObjectType, string.valueOf(val));
                                }
                                if (val != opp.get(mapDIFieldToOppField.get(strDIField))) {
                                    isAllMatch = false;
                                    break;
                                }
                            }
                            if (isAllMatch) {
                                oppBest = opp;
                                // remove this opp from the list to avoid matching it again.
                                listCAOpps.remove(i);
                                break;
                            }
                        }
                    }
                }
                
                // record what we found, either the matched opp or no match
                if (oppBest != null) {
                    di.DonationImportStatus__c = label.bdiMatched;
                    di.DonationImported__c = oppBest.Id;
                    // put the existing opp in our map for caller's use
                    mapDIIdToOpp.put(di.Id, oppBest);
                } else {
                    di.DonationImportStatus__c = label.bdiNoMatch;
                }
                
            }
            
            return mapDIIdToOpp;
        }
    } // BDIMatchingDonations
    
} // BDI_Donations