#ifndef _BG95M3__LTE_H_
#define _BG95M3__LTE_H_


/*----------------------------------------------------------------------------*/
/* includes                                                                   */
#include "DataTypes\inc\DataTypes.h"
/*----------------------------------------------------------------------------*/


/*----------------------------------------------------------------------------*/
/* defines                                                                    */


#define __LTE_ERROR__NO_ERROR__					(U32)0xffffffff		// no error
#define __LTE_ERROR__CONV_ERROR_NUMBER__		(U32)0x0fffffff		// error during vonversion of error code

// 23.5. Summary of CME ERROR Codes
// Final result code +CME ERROR: <err> indicates an error related to mobile equipment or network. The
// operation of +CME ERROR: <err> final result code is similar to the regular ERROR result code: if +CME
// ERROR: <err> is the result code for any of the commands in a command line, none of the following
// commands in the same command line is executed (neither ERROR nor OK result code shall be returned
// as a result of a completed command line execution). The format of <err> can be either numeric or
// verbose. This is set with AT+CMEE.
// The following table lists most of general and GRPS related ERROR codes. For some GSM protocol
// failure cause described in GSM specifications, the corresponding ERROR codes are not included.

#define __LTE_ERROR__PHONE_FAILURE__					0			// Phone failure
#define __LTE_ERROR__NO_CONN_2_PHONE__					1			// No connection to phone
#define __LTE_ERROR__PHONE_ADAPTER_LINK_RESERVED__		2			// Phone-adaptor link reserved
#define __LTE_ERROR__OP_NOT_ALLOWED__					3			// Operation not allowed
#define __LTE_ERROR__OP_NOT_SUPPORTED__					4			// Operation not supported
#define __LTE_ERROR__PH_SIM_PIN_REQUIRED__				5			// PH-SIM PIN required
#define __LTE_ERROR__PH_FSIM_PIN_REQUIRED__				6			// PH-FSIM PIN required
#define __LTE_ERROR__PH_FSIM_PUK_REQUIRED__				7			// PH-FSIM PUK required
#define __LTE_ERROR__SIM_NOT_INSERTED__					10			// (U)SIM not inserted
#define __LTE_ERROR__SIM_PIN_REQUIRED__					11			// (U)SIM PIN required
#define __LTE_ERROR__SIM_PUK_REQUIRED__					12			// (U)SIM PUK required
#define __LTE_ERROR___SIM_FAILURE__						13			// (U)SIM failure
#define __LTE_ERROR__SIM_BUSY__							14			// (U)SIM busy
#define __LTE_ERROR__SIM_WRONG__						15			// (U)SIM wrong
#define __LTE_ERROR__INCORRECT_PW__						16			// Incorrect password
#define __LTE_ERROR__SIM_PIN2_REQUIRED__				17			// (U)SIM PIN2 required
#define __LTE_ERROR__SIM_PUK2_REQUIRED__				18			// (U)SIM PUK2 required
#define __LTE_ERROR__MEM_FULL__							20			// Memory full
#define __LTE_ERROR__INV_INDEX__						21			// Invalid index
#define __LTE_ERROR__NOT_FOUND__						22			// Not found
#define __LTE_ERROR__MEM_FAILURE__						23			// Memory failure
#define __LTE_ERROR__TEXT_STRING_TO_LONG__				24			// Text string too long
#define __LTE_ERROR__INV_CHARS_IN_TEXT_STRING_			25			// Invalid characters in text string
#define __LTE_ERROR__DIAL_STRING_TO_LONG__				26			// Dial string too long
#define __LTE_ERROR__INV_CHARS_IN_DIAL_STRING__			27			// Invalid characters in dial string
#define __LTE_ERROR__NO_NETWOKR_SERVICE__				30			// No network service
#define __LTE_ERROR__NW_TIMEOUT__						31			// Network timeout
#define __LTE_ERROR__NW_NOT_ALLOWED_EMERGENCY_CALLS_ONLY__	32		// Network not allowed - emergency calls only
#define __LTE_ERROR__NW_PERSONAL_PIN_REQUIRED__			40			// Network personalization PIN required
#define __LTE_ERROR__NW_PERSONAL_PUK_REQUIRED__			41			// Network personalization PUK required
#define __LTE_ERROR__NW_SUBSET_PERSONAL_PIN_REQUIRED__	42			// Network subset personalization PIN required
#define __LTE_ERROR__NW_SUBSET_PERSONAL_PUK_REQUIRED__	43			// Network subset personalization PUK required
#define __LTE_ERROR__SRV_PROV_PERSONAL_PIN_REQUIRED__	44			// Service provider personalization PIN required
#define __LTE_ERROR__SRV_PROV_PERSONAL_PUK_REQUIRED__	45			// Service provider personalization PUK required
#define __LTE_ERROR__CORP_PERSONAL_PIN_REQUIRED__		46			// Corporate personalization PIN required
#define __LTE_ERROR__CORP_PERSONAL_PUK_REQUIRESD__		47			// Corporate personalization PUK required

// 23.6. Summary of CMS ERROR Codes
// Final result code +CMS ERROR: <err> indicates an error related to mobile equipment or network. The
// operation is similar to ERROR result code. None of the following commands in the same command line is
// executed. Neither ERROR nor OK result code shall be returned.

#define __LTE_CMS_ERROR__ME_FIALURE__						300			// ME failure
#define __LTE_CMS_ERROR__SMS_ME_RESERVED__					301			// SMS ME reserved
#define __LTE_CMS_ERROR__OP_NOT_ALLOWED__					302			// Operation not allowed
#define __LTE_CMS_ERROR__OP_NOT_SUPPORTED__					303			// Operation not supported
#define __LTE_CMS_ERROR__INV_PDU_MODE__						304			// Invalid PDU mode
#define __LTE_CMS_ERROR__INV_TEXT_MODE__					305			// Invalid text mode
#define __LTE_CMS_ERROR__SIM_NOT_INSERTED__					310			// (U)SIM not inserted
#define __LTE_CMS_ERROR__SIM_PIN_NECESSARY__				311			// (U)SIM pin necessary
#define __LTE_CMS_ERROR__PH_SIM_PIN_NECESSARY__				312			// PH (U)SIM pin necessary
#define __LTE_CMS_ERROR__SIM_FAILURE__						313			// (U)SIM failure
#define __LTE_CMS_ERROR__SIM_BUSY__							314			// (U)SIM busy
#define __LTE_CMS_ERROR__SIM_WRONG__						315			// (U)SIM wrong
#define __LTE_CMS_ERROR__SIM_PUK_REQUIRED__					316			// (U)SIM PUK required
#define __LTE_CMS_ERROR__SIM_PIN2_REQUIRED__				317			// (U)SIM PIN2 required
#define __LTE_CMS_ERROR__SIM_PUK2_REQUIRED__				318			// (U)SIM PUK2 required
#define __LTE_CMS_ERROR__MEM_FAILURE__						320			// Memory failure
#define __LTE_CMS_ERROR__INV_MEM_INDEX__					321			// Invalid memory index
#define __LTE_CMS_ERROR__MEM_FULL__							322			// Memory full
#define __LTE_CMS_ERROR__SMSC_ADDR_UNKNOWN__				330			// SMSC address unknown
#define __LTE_CMS_ERROR__NO_NW__							331			// No network
#define __LTE_CMS_ERROR__NW_TIMEOUT__						332			// Network timeout
#define __LTE_CMS_ERROR__UNKNOWN__							500			// Unknown
#define __LTE_CMS_ERROR__SIM_NOT_READY__					512			// (U)SIM not ready
#define __LTE_CMS_ERROR__MSG_LEN_EXCEEDS__					513			// Message length exceeds
#define __LTE_CMS_ERROR__INV_REQ_PARAMETERS__				514			// Invalid request parameters
#define __LTE_CMS_ERROR__ME_STORAGE_FAILURE__				515			// ME storage failure
#define __LTE_CMS_ERROR__INV_SRV_MODE__						517			// Invalid service mode
#define __LTE_CMS_ERROR__MORE_MSG_TO_SEND_STATE_ERROR__		528			// More message to send state error
#define __LTE_CMS_ERROR__MO_SMS_IS_NOT_ALLOW__				529			// MO SMS is not allow
#define __LTE_CMS_ERROR__GPRS_IS_SUSPENDED__				530			// GPRS is suspended
#define __LTE_CMS_ERROR__ME_STORAGE_FULL__					531			// ME storage full

// The <errcode> indicates an error related to the GNSS operation. The details about <errcode> are
// described in the following table.
#define __LTE_GNSS_ERROR__INV_PARAMETER__				501			// Invalid parameter
#define __LTE_GNSS_ERROR__OP_NOT_SUPPORTED__			502			// Operation not supported
#define __LTE_GNSS_ERROR__GNSS_SUBSYSTEM_BUSY__			503			// GNSS subsystem busy
#define __LTE_GNSS_ERROR__SESSION_IS_ONGOING__			504			// Session is ongoing
#define __LTE_GNSS_ERROR__SESSION_NOT_ACTIVE__			505			// Session not active
#define __LTE_GNSS_ERROR__OP_TIMEOUT__					506			// Operation timeout
#define __LTE_GNSS_ERROR__FCT_NOT_ENABLED__				507			// Function not enabled
#define __LTE_GNSS_ERROR__TIME_INFO_ERROR_				508			// Time information error
#define __LTE_GNSS_ERROR__XTRA_NOT_ENABLED__			509			// XTRA not enabled
#define __LTE_GNSS_ERROR__VALIDITY_TIME_OUT_OF_RANGE__	512			// Validity time is out of range
#define __LTE_GNSS_ERROR__INTERNAL_RES_ERROR__			513			// Internal resource error
#define __LTE_GNSS_ERROR__GNSS_LOCKED__					514			// GNSS locked
#define __LTE_GNSS_ERROR__END_BY_E911__					515			// End by E911
#define __LTE_GNSS_ERROR__NO_FIX__						516			// No fix
#define __LTE_GNSS_ERROR__GEO_FENCE_ID_NOT_EXIST__		517			// Geo-fence ID does not exist
#define __LTE_GNSS_ERROR__SYNC_TIME_FAILED__			518			// Sync time failed
#define __LTE_GNSS_ERROR__XTRA_FILE_NOT_EXIST__			519			// XTRA file does not exist
#define __LTE_GNSS_ERROR__XTRA_FILE_ON_DOWNLOADING__	520			// XTRA file on downloading
#define __LTE_GNSS_ERROR__XTRA_FILE_IS_VALID__			521			// XTRA file is valid
#define __LTE_GNSS_ERROR__GNSS_IS_WORKING__				522			// GNSS is working
#define __LTE_GNSS_ERROR__TIME_INJECTION_ERROR__		523			// Time injection error
#define __LTE_GNSS_ERROR__XTRA_FILE_IS_INVALID__		524			// XTRA file is invalid
#define __LTE_GNSS_ERROR__UNKNOWN_ERROR__				549			// Unknown error

#define __LTE_REVISION_LEN__		14		// BG95M3LAR02A03
#define __LTE_IMEI_LEN__			15		// 864475047617575
#define __LTE_IMSI_LEN__			15		// 901288800469502
#define __LTE_ICCID_LEN__			22		// 89882390000360614591
#define __LTE_NWINFO_LEN__			64

// +COPS: (1,"Telekom.de","TDG","26201",9),(1,"Telekom.de","TDG","26201",8),(1,"Vodafone.de","Vodafone","26202",9),(1,"o2 - de","o2 - de","26203",9),(1,"o2 - de","o2 - de","26203",8),,(0,1,2,3,4),(0,1,2)
//        (<stat>, <oper>, <oper>, <numeric oper>, <Act>)
//
// <stat>  Integer type.
//         0  Unknown
//         1  Operator available
//         2  Current operator
//         3  Operator forbidden
// <oper>   String type. Operator in format as per <mode> (long and/or short alphanumeric)
//          <format> Integer type.
//          0 Long format alphanumeric <oper> which can be up to 16 characters.
//          1 Short format alphanumeric <oper>
//          2 Numeric <oper>. GSM location area identification number.
// <Act>    Integer type. Access technology selected.
//          0  GSM
//          1  eMTC (enhanced Machine Type Communication bzw. LTE-M)
//          9  NB-IoT
enum Enum_LTE_Stat_Items {
	enStat__Unknown=0,			// Unknown
	enStat__OperAvail=1,		// Operator available
	enStat__CurrentOper=2,		// Current operator
	enStat__OperForbidden=3,	// Operator forbidden
	enStat_LastItem=4
};
enum Enum_LTE_Act_Items {
	enAct__GSM=0,				// GSM
	enAct__eMTC=1,				// eMTC
	enAct__NB_IOT=9				// NB-IoT
};


#define __LTE_OPERATOR_LEN__			16
#define __LTE_MAX_NUM_OPER__			15//10
#define __LTE_ESIM_EID_LEN__			32
typedef struct LTE_OpInfo{
	U8 uStat;
	U8 uOperStr[__LTE_OPERATOR_LEN__];		// Short format alphanumeric <oper>
	U8 uOperStrLong[__LTE_OPERATOR_LEN__];	// Long format alphanumeric <oper> which can be up to 16 characters.
	U32 uOperNum;							// Numeric <oper>. GSM location area identification number.
	U8 uAct;								// access technology
}LTE_OpInfo_t;

typedef struct LTE_Info{
	U8 uRevision[__LTE_REVISION_LEN__];
	U8 uIMEI[__LTE_IMEI_LEN__];				// international mobile equipment identify (IMEI)
	bool bPIN_Ready;						// personal identification number OK (PIN)
	U8 uIMSI[__LTE_IMSI_LEN__];				// International Mobile Subscriber Identity (IMSI)
	U8 uICCID[__LTE_ICCID_LEN__];			// Integrated Circuit Card IDentifier (ICCID)
	U8 uESIM_EID[__LTE_ESIM_EID_LEN__];
	
	S32 sTemp_PMIC;							// temperature of PMIC (power management)
	S32 sTemp_XO;							// temperature of XO (oscillator)
	S32 sTemp_PA;							// temperature of PA (power amplifier)
	S32 sTemp_BB;							// temperature of BB (baseband)
	
	U8 uLast_NW_SyncTime_Valid;				// 0: valid, <>0: invalid
	time tLast_NW_SyncTime_GMT;				// last network synchronisation time (GMT)
	
	time tRtcTime_GMT;
	time tRtcTime;
	S32 sOfsZZ;								// offset to GMT in [min]
	
	U8 uRSSI;								// Received signal strength level ("AT+CSQ")
	U8 uBer;								// channel bit error rate in percent ("AT+CSQ")
	U8 uNW_Info[__LTE_NWINFO_LEN__];		// network information
	
	// serving cell information
	
	U16 uSCI__MCC;							// <MCC> Integer type. A three-digit value indicating mobile country code (the first part of the
											//       PLMN code).
	U8 uSCI__MNC;							// <MNC> Integer type. A two-digit value indicating the mobile network code (the second part of
											//		 the PLMN code).
	U32 uSCI__CellID;						// <cellID> Hexadecimal format. 16-bit (GSM) or 28-bit (LTE) cell ID. Range: 00xFFFFFFF.
	U32 uSCI__PCI;							// <PCI> Integer type. Physical cell identity.
	U32 uSCI__EARFCN;						// <EARFCN> Integer type. E-UTRA absolute radio frequency channel number.
	U32 uSCI__FreqBandInd;					// <freq_band_ind> Integer type. E-UTRA frequency bands (see 3GPP 36.101).
	U8 uSCI__UL_bandwidth;					// <UL_bandwidth> Integer type. UL bandwidth.
											// 0 1.4 MHz
											// 1 3 MHz
											// 2 5 MHz
											// 3 10 MHz
											// 4 15 MHz
											// 5 20 MHz
	U8 uSCI__DL_bandwidth;					// <DL_bandwidth> Integer type. DL bandwidth.
											// 0 1.4 MHz
											// 1 3 MHz
											// 2 5 MHz
											// 3 10 MHz
											// 4 15 MHz
											// 5 20 MHz
	U32 uSCI__TAC;							// <TAC> Tracking area code in hexadecimal format (see 3GPP 23.003 subclause 19.4.2.3).
	S32 sSCI__RSRP;							// <RSRP> Reference signal received power (see 3GPP 36.214 subclause 5.1.1). Unit: dBm.
	S32 sSCI__RSRQ;							// <RSRQ> Reference signal received quality (see 3GPP 36.214 subclause 5.1.3). Unit: dB.
	S32 sSCI__RSSI;							// <RSSI> Integer type. The received signal strength indication. Unit: dBm.
	S32 sSCI__SINR;							// <SINR> Integer type. A converted value of SINR. The actual SINR = (1/5)  <SINR> - 20.
											// Range: 0250 (that is, the actual SINR ranges between -20 dB and 30 dB). .
	S32 sSCI__Srxlev;						// <srxlev> Integer type. Cell selection Rx level value (in dB) (see 3GPP 36.304).
	
	LTE_OpInfo_t aOperators[__LTE_MAX_NUM_OPER__];
}LTE_Info_t;

/*----------------------------------------------------------------------------*/


/*----------------------------------------------------------------------------*/
/* prototypes                                                                 */
void Init_BG95M3(void);
// power on reset LTE module
void TurnOff_BG95M3(void);
bool TurnOn_BG95M3(void);
// reset LTE module
void StartReset_BG95M3(void);
bool Reset_BG95M3(void);

bool IsOff_BG95M3(void);

U8* BG95M3_GetOperStatStr(U8 uStat);
U8* BG95M3_GetOperActStr(U8 uAct);
/*----------------------------------------------------------------------------*/


#endif  /* _BG95M3__LTE_H_ */
